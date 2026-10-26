import AppKit
import LumenCore
import LumenRender
import Observation

enum LibraryBadge: String, CaseIterable {
    case measured = "Measured", misfire = "Misfire", auto = "Auto", straightened = "Straightened"
    case edited = "Edited", attention = "Needs attention", failed = "Failed"
}

struct LibraryPhotoState {
    var badges: Set<LibraryBadge> = []
    var facts: PhotoFacts?
    var review: PhotoReview?
    var reason: String?
    var revision = 0
}

enum LibraryStraighten: String, CaseIterable, Decodable, Sendable {
    case ask, yes, no
    var value: Bool? { switch self { case .ask: nil; case .yes: true; case .no: false } }
}

/// Presents one library run, including the decisions that pause it.
@MainActor @Observable
final class StudioLibraryModel {
    let backends: StudioBackends
    var instruction = ""
    var mode = BatchMode.askWhenUnsure
    var auto = true
    var straighten = LibraryStraighten.ask
    var flagMisfires = true
    var qualityThreshold = 0.5
    var compare = false
    var output: URL?
    var issue: String?
    var selectedGroup: String?
    private(set) var folder: URL?
    private(set) var photos: [PhotoID] = []
    private(set) var states: [PhotoID: LibraryPhotoState] = [:]
    private(set) var isOpening = false
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var status = "Open a folder to begin"
    private(set) var done = 0
    private(set) var total = 0
    private(set) var modelCalls = 0
    private(set) var question: BatchQuestion?
    private(set) var decisions: [BatchAnswer] = []
    private(set) var plan: BatchPlan?
    private(set) var estimatedModelCalls: Int?
    private(set) var summary: BatchSummary?
    private(set) var events: [StudioStep] = []
    private(set) var recentDecision: BatchAnswer?
    @ObservationIgnored private let makeLibrary: (URL, URL) throws -> any LibraryHost
    @ObservationIgnored private var library: StudioLibraryHost?
    @ObservationIgnored private var agent: BatchAgent?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var photoEvents: [PhotoID: [AgentEvent]] = [:]
    @ObservationIgnored private var decisionTask: Task<Void, Never>?
    @ObservationIgnored private var runThreshold = 0.5
    @ObservationIgnored private var hasRun = false

    init(backends: StudioBackends = StudioBackends(),
         makeLibrary: @escaping (URL, URL) throws -> any LibraryHost = { try FolderLibrary(folder: $0, output: $1) }) {
        self.backends = backends
        self.makeLibrary = makeLibrary
    }

    var canRun: Bool { !isOpening && !isRunning && !hasRun && !photos.isEmpty }
    var highlightedPhotos: Set<PhotoID> {
        if let question { return affectedPhotos(question) }
        if let plan, estimatedModelCalls != nil {
            return Set(plan.groups.filter { selectedGroup == nil || $0.id == selectedGroup }.flatMap(\.photos))
        }
        if let recentDecision { return affectedPhotos(recentDecision.question) }
        return []
    }

    func affectedPhotos(_ question: BatchQuestion) -> Set<PhotoID> {
        if question.id == "straighten" {
            return Set(photos.filter { abs(states[$0]?.facts?.tilt ?? 0) >= 0.5 })
        }
        return Set(plan?.groups.filter { question.groups.contains($0.id) }.flatMap(\.photos) ?? [])
    }

    func openFolder(_ folder: URL, output: URL? = nil) async throws {
        guard !isRunning && !isOpening else { throw StudioScriptError.message("Wait for this library to stop before opening another.") }
        isOpening = true
        defer { isOpening = false }
        let destination = output ?? folder.appendingPathComponent("Lumen", isDirectory: true)
        let host = StudioLibraryHost(try makeLibrary(folder, destination))
        let found = try await host.photos()
        self.folder = folder
        self.output = destination
        library = host
        var seen: Set<PhotoID> = []
        photos = found.filter { seen.insert($0).inserted }
        states = Dictionary(uniqueKeysWithValues: photos.map { ($0, LibraryPhotoState()) })
        hasRun = false
        resetRun()
        total = photos.count
        status = photos.isEmpty ? "No JPEG, PNG or HEIC photos in this folder" : "\(photos.count) photos ready"
    }

    func changeOutput(_ url: URL) async throws {
        guard !hasRun, let folder else { throw StudioScriptError.message("Choose the output before running.") }
        try await openFolder(folder, output: url)
    }

    func run() {
        guard canRun, runTask == nil else { return }
        runTask = Task {
            do { try await runLibrary() }
            catch { if !isCancellation(error) { issue = error.localizedDescription } }
            runTask = nil
        }
    }

    /// Uses the same batch agent for the window and scripted captures.
    func runLibrary(using suppliedModels: StudioModels? = nil, options suppliedOptions: BatchOptions? = nil,
                    allowKeychainInteraction: Bool = true,
                    onEvent: @MainActor (BatchEvent) async throws -> Void = { _ in }) async throws {
        guard canRun, let library else { throw StudioScriptError.message("Open a library before running.") }
        let options = suppliedOptions ?? BatchOptions(mode: mode, instruction: instruction, auto: auto,
            straighten: straighten.value, flagMisfires: flagMisfires, qualityThreshold: qualityThreshold)
        resetRun()
        runThreshold = options.qualityThreshold
        isRunning = true
        status = "Preparing the planner"
        defer {
            isRunning = false
            isStopping = false
            question = nil
            estimatedModelCalls = nil
            agent = nil
        }
        do {
            let models: StudioModels
            if let suppliedModels { models = suppliedModels }
            else { models = try await backends.models(allowKeychainInteraction: allowKeychainInteraction) }
            try Task.checkCancellation()
            guard !isStopping else { throw LumenError.cancelled }
            let agent = BatchAgent(host: library, reviewer: models.reviewer, planner: models.planner,
                                   segmenter: models.segmenter, generator: models.generator)
            self.agent = agent
            hasRun = true
            for try await event in await agent.run(options) {
                try Task.checkCancellation()
                receive(event)
                try await onEvent(event)
            }
        } catch {
            await agent?.cancel()
            status = isCancellation(error) ? "Stopped" : "Library stopped"
            if !isCancellation(error) { issue = error.localizedDescription }
            throw error
        }
    }

    func answer(_ option: String) async {
        guard let question, question.options.contains(option), !isStopping else { return }
        await agent?.answer(question.id, with: option)
        self.question = nil
        status = "Continuing with your answer"
    }

    func approve() async {
        guard estimatedModelCalls != nil, !isStopping else { return }
        estimatedModelCalls = nil
        selectedGroup = nil
        status = "Applying the plan"
        await agent?.approve()
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        status = "Stopping"
        runTask?.cancel()
        Task { await agent?.cancel() }
    }

    func close() async {
        stop()
        await agent?.cancel()
        await runTask?.value
        await backends.shutdown()
    }

    func openPhoto(_ photo: PhotoID, in model: StudioModel) async throws {
        guard !isRunning, let library, let folder, photos.contains(photo) else {
            throw StudioScriptError.message("Stop the library before opening a photo's layers.")
        }
        let host = try await library.photoHost(photo)
        try await model.openLibraryPhoto(folder.appendingPathComponent(photo.rawValue), host: host,
                                         events: photoEvents[photo] ?? [])
    }

    func thumbnail(_ photo: PhotoID) async throws -> EncodedImage {
        guard let library else { throw StudioScriptError.message("No library is open.") }
        return try await library.thumbnail(photo, maxLongEdge: 360)
    }

    func refreshPhoto(_ photo: PhotoID) { states[photo]?.revision += 1 }

    func revealOutput() {
        guard let output else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: output.path)
    }

    func chooseOutput() {
        guard canRun else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the results folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = output
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await self?.changeOutput(url) }
                catch { self?.issue = error.localizedDescription }
            }
        }
    }

    func receive(_ event: BatchEvent) {
        var title: String?
        var detail: String?
        var symbol = "checkmark"
        var trace: TraceEvent?
        switch event {
        case .found(let count): total = count; title = "Measuring \(count) photos"; symbol = "viewfinder"
        case .measured(let photo, let facts):
            states[photo]?.facts = facts
            states[photo]?.badges.insert(.measured)
            status = "Measured \(photo.rawValue)"
        case .reviewed(let review):
            states[review.photo]?.review = review
            if review.quality < runThreshold { states[review.photo]?.badges.insert(.attention) }
            title = "Reviewed \(review.photo.rawValue)"; detail = review.description; symbol = "text.bubble"
        case .flagged(let photo, let reason):
            states[photo]?.badges.insert(.misfire)
            states[photo]?.badges.remove(.attention)
            states[photo]?.reason = reason
            title = "Flagged \(photo.rawValue)"; detail = reason; symbol = "flag"
        case .autoApplied(let photo, let label):
            states[photo]?.badges.insert(.auto); refreshPhoto(photo)
            title = "Auto · \(photo.rawValue)"; detail = label; symbol = "slider.horizontal.3"
        case .straightened(let photo, let degrees):
            states[photo]?.badges.insert(.straightened); refreshPhoto(photo)
            title = "Straightened \(photo.rawValue)"; detail = "\(degrees.formatted())°"; symbol = "rotate.left"
        case .planned(let plan): self.plan = plan; title = "Library plan"; detail = plan.summary; symbol = "list.bullet.indent"
        case .question(let question): self.question = question; title = question.question; symbol = "questionmark.bubble"
        case .answered(let answer):
            question = nil
            decisions.append(answer)
            recentDecision = answer
            decisionTask?.cancel()
            decisionTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                self?.recentDecision = nil
            }
            title = "Decided: \(answer.answer)"; detail = answer.question.question; symbol = "text.bubble"
        case .awaitingApproval(let plan, let calls):
            self.plan = plan; estimatedModelCalls = calls
            title = "Ready for your approval"; detail = "About \(calls) more model calls"; symbol = "pause.circle"
        case .editStarted(let photo, let instruction):
            title = "Editing \(photo.rawValue)"; detail = instruction; symbol = "paintbrush.pointed"
        case .edit(let photo, let event):
            switch event {
            case .selected: break
            case .applied:
                states[photo]?.badges.insert(.edited); refreshPhoto(photo)
            case .reverted: refreshPhoto(photo)
            default: photoEvents[photo, default: []].append(event)
            }
            if case .trace(let value) = event {
                trace = value; title = "\(photo.rawValue) · \(value.kind.rawValue.capitalized)"; detail = value.detail
                if value.kind == .failure { states[photo]?.badges.insert(.attention); states[photo]?.reason = value.detail }
            }
        case .editFinished(let result):
            apply(result); refreshPhoto(result.photo)
            title = "Finished \(result.photo.rawValue)"; detail = result.outcome
        case .progress(let done, let total): self.done = done; self.total = total
        case .finished(let summary):
            self.summary = summary; modelCalls = summary.modelCalls
            for result in summary.photos { apply(result); refreshPhoto(result.photo) }
            title = "Finished · \(summary.photos.count) photos"; symbol = "checkmark.seal"
        case .trace(let value): trace = value; title = value.kind.rawValue.capitalized; detail = value.detail; symbol = "waveform.path"
        }
        if let trace, trace.model != nil { modelCalls += 1 }
        if case .finished(let summary) = event { modelCalls = summary.modelCalls }
        if let title {
            status = title
            events.append(StudioStep(title: title, symbol: symbol, detail: detail,
                                     status: trace?.kind == .failure ? .failed(detail ?? "Failed") : .done,
                                     traces: trace.map { [$0] } ?? [], kind: .trace))
            if events.count > 80 { events.removeFirst(events.count - 80) }
        }
    }

    var timelineText: String {
        let lines = events.map { "\($0.title)\($0.detail.map { "\n" + $0 } ?? "")" }
        let choices = decisions.map { "\($0.question.question)\nDecided: \($0.answer)" }
        return (["Library: \(folder?.path ?? "")", "Instruction: \(instruction)", "Model calls: \(modelCalls)"] + choices + lines).joined(separator: "\n\n") + "\n"
    }

    private func apply(_ result: BatchPhotoResult) {
        if result.auto != nil { states[result.photo]?.badges.insert(.auto) }
        if result.straightened != nil { states[result.photo]?.badges.insert(.straightened) }
        if let reason = result.flagged { states[result.photo]?.badges.insert(.misfire); states[result.photo]?.reason = reason }
        if result.failed { states[result.photo]?.badges.insert(.failed); states[result.photo]?.reason = result.outcome }
        else if result.instruction != nil {
            let limited = result.outcome?.localizedCaseInsensitiveContains("limit reached") == true
            if limited { states[result.photo]?.badges.insert(.attention) }
            else { states[result.photo]?.badges.remove(.attention) }
        }
        if result.outcome?.hasPrefix("Skipped:") == true { states[result.photo]?.badges.insert(.attention) }
    }

    private func resetRun() {
        decisionTask?.cancel()
        question = nil; recentDecision = nil; decisions = []; plan = nil; selectedGroup = nil
        estimatedModelCalls = nil; summary = nil; events = []; photoEvents = [:]
        done = 0; modelCalls = 0; issue = nil
    }

    private func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || error as? LumenError == .cancelled
    }
}
