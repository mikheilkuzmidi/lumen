import AppKit
import LumenCore
import LumenMeta
import LumenRender
import Observation
import UniformTypeIdentifiers

enum StudioPhase: Equatable {
    case idle, opening, running, stopping, updating, exporting
}

enum StepStatus: Equatable {
    case waiting, running, done
    case skipped(String)
    case failed(String)

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .running: "Running"
        case .done: "Done"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }

    var message: String? {
        switch self {
        case .skipped(let message), .failed(let message): message
        default: nil
        }
    }
}

struct StudioStep: Identifiable {
    enum Kind { case planning, step, critique, revision, finish, trace }

    let id = UUID()
    var title: String
    var symbol: String
    var detail: String?
    var status: StepStatus
    var step: EditStep?
    var traces: [TraceEvent] = []
    var kind: Kind = .step
}

struct StudioRegion: Identifiable {
    let id = UUID()
    let selectedAt = Date()
    let name: String
    let segment: Segment
    let colorIndex: Int
    let mask: NSImage?

    init(name: String, segment: Segment, colorIndex: Int) {
        self.name = name
        self.segment = segment
        self.colorIndex = colorIndex
        let data = Data(segment.mask.coverage)
        let size = segment.mask.size
        if size.width > 0, size.height > 0,
           let provider = CGDataProvider(data: data as CFData),
           let image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8,
                               bitsPerPixel: 8, bytesPerRow: size.width,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            mask = NSImage(cgImage: image, size: NSSize(width: size.width, height: size.height))
        } else {
            mask = nil
        }
    }
}

/// Owns the photo, edit task, timeline, and reversible layer history for one window.
@MainActor @Observable
final class StudioModel {
    let backends: StudioBackends
    var prompt = ""
    var area: NormalizedRect?
    var zoom: Double = 1
    var compare = false
    var holdingCompare = false
    var sidebar = StudioSidebarTab.steps
    var snapshotDate: Date?
    var issue: String?
    private(set) var phase = StudioPhase.idle
    private(set) var photoURL: URL?
    private(set) var photoSize = PixelSize(width: 0, height: 0)
    private(set) var preview: NSImage?
    private(set) var original: NSImage?
    private(set) var layers: [Layer] = []
    private(set) var steps: [StudioStep] = []
    private(set) var regions: [StudioRegion] = []
    private(set) var planSummary = ""
    private(set) var completion: String?
    private(set) var historyPosition = 0
    private(set) var historyCount = 1

    @ObservationIgnored private var document: (any StudioPhoto)?
    @ObservationIgnored private var originalDocument: (any StudioPhoto)?
    @ObservationIgnored private let makePhoto: (URL) throws -> any StudioPhoto
    @ObservationIgnored private var host: StudioPhotoHost?
    @ObservationIgnored private var agentTask: Task<Void, Never>?
    @ObservationIgnored private var history: [[Layer]] = [[]]
    @ObservationIgnored private var activeStep: UUID?
    @ObservationIgnored private var regionColors: [String: Int] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var planCount = 0
    @ObservationIgnored private var pendingRevision: [EditStep]?
    @ObservationIgnored private var renderEdge = 1600
    @ObservationIgnored private var renderVersion = 0
    @ObservationIgnored private var originalEdge = 0
    @ObservationIgnored private var photoVersion = UUID()

    init(backends: StudioBackends = StudioBackends(),
         makePhoto: @escaping (URL) throws -> any StudioPhoto = { try PhotoDocument(contentsOf: $0) }) {
        self.backends = backends
        self.makePhoto = makePhoto
    }

    var isBusy: Bool { phase != .idle }
    var isRunning: Bool { phase == .running || phase == .stopping }
    var showsOriginal: Bool { compare || holdingCompare }
    var canRun: Bool { document != nil && preview != nil && !isBusy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canUndo: Bool { !isBusy && historyPosition > 0 }
    var canRedo: Bool { !isBusy && historyPosition + 1 < historyCount }
    var canExport: Bool { document != nil && preview != nil && !isBusy }
    var timelineFocus: UUID? { activeStep ?? steps.last(where: { $0.status != .waiting })?.id }

    var status: String {
        if let status = backends.status, backends.isLoading || phase == .idle { return status }
        switch phase {
        case .opening: return "Opening photo"
        case .running: return steps.first(where: { $0.id == activeStep })?.title ?? "Working on your edit"
        case .stopping: return "Stopping"
        case .updating: return "Updating layers"
        case .exporting: return "Exporting full-size photo"
        case .idle: return completion ?? (photoURL == nil ? "A new perspective starts here" : "Ready for your next edit")
        }
    }

    func choosePhoto() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a photo"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    func open(_ url: URL) {
        guard !isBusy, url.isFileURL else { return }
        Task {
            do { try await openPhoto(url) }
            catch { issue = error.localizedDescription }
        }
    }

    func openPhoto(_ url: URL) async throws {
        guard !isBusy, url.isFileURL else { throw StudioScriptError.message("A photo can't be opened right now.") }
        phase = .opening
        issue = nil
        defer { phase = .idle }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let photo = try makePhoto(url)
            let original = try makePhoto(url)
            let encoded = try await photo.render(maxLongEdge: renderEdge)
            guard let image = NSImage(data: encoded.data) else { throw StudioPhotoError.unreadablePreview }
            document = photo
            originalDocument = original
            host = StudioPhotoHost(photo: photo)
            photoURL = url
            photoVersion = UUID()
            photoSize = await photo.size()
            preview = image
            self.original = image
            originalEdge = renderEdge
            zoom = 1
            compare = false
            holdingCompare = false
            area = nil
            layers = []
            steps = []
            regions = []
            regionColors = [:]
            planSummary = ""
            completion = nil
            sidebar = .steps
            history = [[]]
            historyPosition = 0
            historyCount = 1
        } catch { issue = error.localizedDescription; throw error }
    }

    func renderPreview(maxLongEdge: Int) async {
        renderEdge = max(1, maxLongEdge)
        guard let document else { return }
        renderVersion += 1
        let version = renderVersion
        let photo = photoVersion
        do {
            let encoded = try await document.render(maxLongEdge: renderEdge)
            try Task.checkCancellation()
            guard photo == photoVersion, version == renderVersion else { return }
            guard let image = NSImage(data: encoded.data) else { throw StudioPhotoError.unreadablePreview }
            preview = image
            if originalEdge != renderEdge, let originalDocument {
                let originalImage = try await originalDocument.render(maxLongEdge: renderEdge)
                try Task.checkCancellation()
                guard photo == photoVersion, version == renderVersion else { return }
                guard let image = NSImage(data: originalImage.data) else { throw StudioPhotoError.unreadablePreview }
                original = image
                originalEdge = renderEdge
            }
        } catch is CancellationError {
        } catch {
            if photo == photoVersion, version == renderVersion { issue = error.localizedDescription }
        }
    }

    func run() {
        guard canRun, agentTask == nil else { return }
        agentTask = Task {
            do { try await runEdit() }
            catch {
                if !Task.isCancelled, !(error is CancellationError), (error as? LumenError) != .cancelled {
                    issue = error.localizedDescription
                }
            }
            agentTask = nil
        }
    }

    /// Runs the same edit for the window and a script, reporting events after the view model updates.
    func runEdit(using suppliedModels: StudioModels? = nil,
                 allowKeychainInteraction: Bool = true,
                 onEvent: @MainActor (AgentEvent) async throws -> Void = { _ in }) async throws {
        guard canRun, let host else { throw StudioScriptError.message("Open a photo and enter an instruction before running.") }
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedArea = area
        phase = .running
        compare = false
        holdingCompare = false
        issue = nil
        backends.issue = nil
        completion = nil
        steps = [StudioStep(title: "Planning your edit", symbol: "sparkle",
                            detail: backends.selection == .glimmer ? "Muse Glimmer may take a minute or more to plan on this Mac." : nil,
                            status: .running, kind: .planning)]
        activeStep = steps.first?.id
        planSummary = ""
        planCount = 0
        revision = 0
        pendingRevision = nil
        regions = []
        sidebar = .steps
        var agent: EditAgent?
        var failure: (any Error)?
        do {
            let models: StudioModels
            if let suppliedModels { models = suppliedModels }
            else { models = try await backends.models(allowKeychainInteraction: allowKeychainInteraction) }
            let edit = EditAgent(planner: models.planner, segmenter: models.segmenter, generator: models.generator, host: host)
            agent = edit
            for try await event in edit.run(instruction, area: requestedArea) {
                try Task.checkCancellation()
                await receive(event)
                try await onEvent(event)
            }
            if Task.isCancelled {
                finishStopped()
            } else if completion == nil {
                finishActive()
                skipWaiting("The edit ended before this step.")
                completion = "Edit ended"
            }
        } catch {
            await agent?.cancel()
            failure = error
            if Task.isCancelled || error is CancellationError || (error as? LumenError) == .cancelled {
                finishStopped()
            } else {
                failActive(error.localizedDescription)
                issue = error.localizedDescription
                skipWaiting("The edit stopped before this step.")
            }
        }
        layers = await host.layers()
        remember(layers)
        await Task { await renderPreview(maxLongEdge: renderEdge) }.value
        regions = []
        phase = .idle
        if let failure { throw failure }
    }

    func stop() {
        guard phase == .running else { return }
        phase = .stopping
        agentTask?.cancel()
    }

    func chooseBackend(_ backend: StudioScript.Backend) {
        if backends.selection != backend, isRunning { stop() }
        backends.choose(backend)
    }

    func close() async {
        agentTask?.cancel()
        await backends.shutdown()
    }

    func toggleLayer(_ id: UUID) {
        guard !isBusy, let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].isEnabled.toggle()
        commitLayerChanges()
    }

    func setOpacity(_ value: Double, for id: UUID) {
        guard !isBusy, let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].opacity = min(1, max(0, value))
    }

    func commitLayerChanges() {
        guard !isBusy, layers != history[historyPosition] else { return }
        restore(layers, historyTarget: nil)
    }

    func undo() {
        guard canUndo else { return }
        restore(history[historyPosition - 1], historyTarget: historyPosition - 1)
    }

    func redo() {
        guard canRedo else { return }
        restore(history[historyPosition + 1], historyTarget: historyPosition + 1)
    }

    func chooseExport() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.title = "Export photo at full size"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canSelectHiddenExtension = true
        panel.nameFieldStringValue = (photoURL?.deletingPathExtension().lastPathComponent ?? "Photo") + " edited.png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.export(to: url) }
        }
    }

    private func export(to url: URL) {
        guard canExport else { return }
        Task {
            do { try await exportPhoto(to: url) }
            catch { issue = error.localizedDescription }
        }
    }

    func exportPhoto(to url: URL) async throws {
        guard canExport, let document else { throw StudioScriptError.message("No photo is ready to export.") }
        phase = .exporting
        issue = nil
        defer { phase = .idle }
        do {
            let format: EncodedImage.Format = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
            try await document.export(to: url, format: format)
            completion = "Exported \(url.lastPathComponent)"
        } catch { issue = error.localizedDescription; throw error }
    }

    private func restore(_ snapshot: [Layer], historyTarget: Int?) {
        guard let host else { return }
        phase = .updating
        issue = nil
        Task {
            do {
                try await host.restore(snapshot)
                layers = await host.layers()
                if let historyTarget { historyPosition = historyTarget }
                else { remember(layers) }
                completion = nil
            } catch {
                layers = await host.layers()
                if layers != history[historyPosition] { remember(layers) }
                issue = error.localizedDescription
            }
            await renderPreview(maxLongEdge: renderEdge)
            phase = .idle
        }
    }

    private func remember(_ layers: [Layer]) {
        guard history[historyPosition] != layers else { return }
        history = Array(history.prefix(historyPosition + 1))
        history.append(layers)
        historyPosition = history.count - 1
        historyCount = history.count
    }

    private func receive(_ event: AgentEvent) async {
        switch event {
        case .planned(let plan):
            finishActive()
            if pendingRevision == plan.steps, planCount > 0 {
                planSummary = plan.summary
                if let index = steps.lastIndex(where: { $0.kind == .revision }) { steps[index].detail = plan.summary }
                pendingRevision = nil
                planCount += 1
                return
            }
            pendingRevision = nil
            if planCount > 0 {
                skipWaiting("Replaced by a revised plan.")
                revision += 1
                steps.append(StudioStep(title: "Revision \(revision)", symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                                        detail: plan.summary, status: .done, kind: .revision))
            }
            planCount += 1
            planSummary = plan.summary
            appendSteps(plan.steps)
        case .stepStarted(_, let step):
            finishActive()
            pendingRevision = nil
            if case .select = step { regions = [] }
            if let index = steps.firstIndex(where: { $0.step == step && $0.status == .waiting }) {
                steps[index].status = .running
                activeStep = steps[index].id
            } else {
                let row = StudioStep(title: step.studioLabel, symbol: step.studioSymbol, status: .running, step: step)
                steps.append(row)
                activeStep = row.id
            }
        case .selected(let name, let segment):
            let color = regionColors[name] ?? regionColors.count
            regionColors[name] = color
            regions.append(StudioRegion(name: name, segment: segment, colorIndex: color))
        case .applied(let layer):
            finishActive()
            if let index = layers.firstIndex(where: { $0.id == layer.id }) { layers[index] = layer }
            else { layers.append(layer) }
            remember(layers)
            await renderPreview(maxLongEdge: renderEdge)
            regions = []
        case .reverted(let id):
            finishActive()
            layers.removeAll { $0.id == id }
            remember(layers)
            await renderPreview(maxLongEdge: renderEdge)
        case .critiqued(let critique):
            finishActive()
            let title = critique.satisfied ? "Result checked" : "Refining the result"
            if let index = steps.lastIndex(where: { $0.kind == .critique && $0.detail == nil }) {
                steps[index].title = title
                steps[index].detail = critique.notes
            } else {
                steps.append(StudioStep(title: title, symbol: "text.bubble", detail: critique.notes,
                                        status: .done, kind: .critique))
            }
            if !critique.satisfied, !critique.steps.isEmpty {
                skipWaiting("Replaced by the critic’s revision.")
                revision += 1
                steps.append(StudioStep(title: "Revision \(revision)", symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                                        status: .done, kind: .revision))
                appendSteps(critique.steps)
                pendingRevision = critique.steps
            }
        case .finished(let reason):
            finishActive()
            skipWaiting("Not needed after the edit finished.")
            completion = reason
            steps.append(StudioStep(title: "Edit finished", symbol: "checkmark.seal", detail: reason,
                                    status: .done, kind: .finish))
            regions = []
        case .trace(let trace):
            receiveTrace(trace)
        }
    }

    private func appendSteps(_ plan: [EditStep]) {
        steps.append(contentsOf: plan.map { StudioStep(title: $0.studioLabel, symbol: $0.studioSymbol,
                                                       detail: $0.studioDetail, status: .waiting, step: $0) })
    }

    var timelineText: String {
        var lines = ["Photo: \(photoURL?.path ?? "")", "Instruction: \(prompt)", "Plan: \(planSummary)"]
        for (index, step) in steps.enumerated() {
            lines.append("\n\(index + 1). [\(step.status.label)] \(step.title)")
            if let detail = step.detail { lines.append(detail) }
            if let message = step.status.message { lines.append(message) }
            for trace in step.traces {
                lines.append("  [\(trace.kind.rawValue)\(trace.model.map { " " + $0 } ?? "")] \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), trace.duration)) s \(trace.detail)")
            }
        }
        if let issue = issue ?? backends.issue { lines.append("\nError: \(issue)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private func receiveTrace(_ trace: TraceEvent) {
        let index: Int?
        if trace.kind == .plan {
            index = steps.lastIndex(where: {
                ($0.kind == .planning || $0.kind == .revision) && !$0.traces.contains(where: { $0.kind == .plan })
            })
        } else if trace.kind == .critique {
            index = steps.lastIndex(where: { $0.kind == .critique && $0.traces.isEmpty })
        } else if let activeStep {
            index = steps.firstIndex(where: { $0.id == activeStep })
        } else {
            index = steps.lastIndex(where: { $0.step?.type == trace.kind.rawValue })
        }
        if let index {
            steps[index].traces.append(trace)
            if trace.kind == .failure { steps[index].status = .failed(trace.detail) }
        } else {
            let isCritique = trace.kind == .critique
            steps.append(StudioStep(title: isCritique ? "Checking the result" : (trace.kind == .failure ? "Edit failed" : trace.kind.rawValue.capitalized),
                                    symbol: isCritique ? "text.bubble" : (trace.kind == .failure ? "exclamationmark.triangle" : "waveform.path"),
                                    detail: isCritique ? nil : trace.detail,
                                    status: trace.kind == .failure ? .failed(trace.detail) : .done,
                                    traces: [trace], kind: isCritique ? .critique : .trace))
        }
    }

    private func finishActive() {
        guard let activeStep, let index = steps.firstIndex(where: { $0.id == activeStep }) else { return }
        if steps[index].status == .running { steps[index].status = .done }
        self.activeStep = nil
    }

    private func failActive(_ message: String) {
        if let activeStep, let index = steps.firstIndex(where: { $0.id == activeStep }) {
            steps[index].status = .failed(message)
        } else {
            steps.append(StudioStep(title: "Edit failed", symbol: "exclamationmark.triangle", status: .failed(message)))
        }
        activeStep = nil
    }

    private func skipWaiting(_ reason: String) {
        for index in steps.indices where steps[index].status == .waiting { steps[index].status = .skipped(reason) }
    }

    private func finishStopped() {
        if let activeStep, let index = steps.firstIndex(where: { $0.id == activeStep }), steps[index].status == .running {
            steps[index].status = .skipped("Stopped by you.")
        }
        activeStep = nil
        skipWaiting("Stopped before this step.")
        completion = "Stopped"
    }
}

extension EditStep {
    var studioDetail: String? {
        switch self {
        case .regenerate(let regeneration): regeneration.prompt
        case .finish(let finish): finish.reason
        default: nil
        }
    }

    var studioSymbol: String {
        switch self {
        case .select: "viewfinder"
        case .adjust: "slider.horizontal.3"
        case .regenerate: "paintbrush.pointed"
        case .remove: "eraser"
        case .crop: "crop"
        case .revert: "arrow.uturn.backward"
        case .finish: "checkmark"
        }
    }

    var studioLabel: String {
        switch self {
        case .select(let selection): "Find \(selection.concept ?? selection.id)"
        case .adjust(let adjustment): "Adjust \(adjustment.region ?? "the photo")"
        case .regenerate(let regeneration): "Redraw \(regeneration.region)"
        case .remove(let removal): "Remove \(removal.region)"
        case .crop: "Crop the photo"
        case .revert(let revert): "Undo \(revert.layer)"
        case .finish: "Finish the edit"
        }
    }
}

enum StudioSidebarTab: Hashable { case steps, layers }

/// The models used by an edit, replaceable for offline runs in tests.
struct StudioModels: Sendable {
    let planner: any Planner
    let segmenter: any Segmenter
    let generator: any Generator

    static func meta(allowKeychainInteraction: Bool = true) throws -> StudioModels {
        let configuration = MetaConfiguration(apiKey: try StudioKeychain.runtimeKey(allowInteraction: allowKeychainInteraction))
        return StudioModels(planner: MetaPlanner(configuration: configuration),
                            segmenter: MetaSegmenter(configuration: configuration),
                            generator: MetaGenerator(configuration: configuration))
    }
}
