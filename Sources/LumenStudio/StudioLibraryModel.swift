import AppKit
import LumenCore
import LumenRender
import LumenVoice
import Observation

enum LibraryBadge: String, CaseIterable {
    case measured = "Measured", misfire = "Misfire", auto = "Auto", straightened = "Straightened"
    case edited = "Edited", attention = "Needs attention", failed = "Failed", excluded = "Excluded", unfinished = "Unfinished"
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

@MainActor
private final class LibraryPhotoWindow {
    weak var model: StudioModel?
    let photo: PhotoID
    let url: URL
    var opening = true
    init(model: StudioModel, photo: PhotoID, url: URL) { self.model = model; self.photo = photo; self.url = url }
}

/// Presents one library run, including the decisions that pause it.
@MainActor @Observable
final class StudioLibraryModel {
    let backends: StudioBackends
    var instruction = ""
    var mode = BatchMode.planFirst
    var auto = true
    var straighten = LibraryStraighten.ask
    var flagMisfires = true
    var qualityThreshold = 0.5
    var compare = false
    var output: URL?
    var issue: String?
    /// The microphone beside the library's instruction.
    let voice = StudioVoice.instruction()
    var selectedGroup: String?
    var selectedPhotos: Set<PhotoID> = []
    var scope = StudioLibraryScope.currentView
    var reviewShown = true
    var instructionOverrides: [String: String] = [:]
    var excludedPhotos: Set<PhotoID> = []
    private(set) var draftPlan: BatchPlan?
    private(set) var isCheckingApproval = false
    private(set) var approvalIssue: String?
    private(set) var runTargets: [PhotoID] = []
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
    private(set) var totalCost: Double = 0
    private(set) var question: BatchQuestion?
    private(set) var decisions: [BatchAnswer] = []
    private(set) var plan: BatchPlan?
    private(set) var estimatedModelCalls: Int?
    private(set) var summary: BatchSummary?
    private(set) var stoppedSnapshot: BatchSnapshot?
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
    @ObservationIgnored private var scopedLibrary: ScopedStudioLibrary?
    @ObservationIgnored private var runScope = StudioLibraryScope.currentView
    @ObservationIgnored private var draftRevision = 0
    @ObservationIgnored private var didMutate = false
    @ObservationIgnored private let leaseID = UUID()
    @ObservationIgnored private var photoWindows: [LibraryPhotoWindow] = []

    init(backends: StudioBackends = StudioBackends(),
         makeLibrary: @escaping (URL, URL) throws -> any LibraryHost = { try FolderLibrary(folder: $0, output: $1) }) {
        self.backends = backends
        self.makeLibrary = makeLibrary
    }

    var scopePhotos: [PhotoID] { scope == .selected ? photos.filter { selectedPhotos.contains($0) } : photos }
    var canRun: Bool { !isOpening && !isRunning && !hasRun && !scopePhotos.isEmpty }
    var approvalEstimate: String {
        if let approvalIssue { return approvalIssue }
        let draft = draftPlan ?? plan
        let calls = draft?.estimatedModelCalls ?? estimatedModelCalls ?? 0
        return "About \(calls) more model calls" + (draft?.estimatedCost.map { ", about " + studioDollars($0, estimated: true) + " USD" } ?? "")
    }
    var completionDetail: String {
        if let snapshot = stoppedSnapshot {
            var parts = ["\(snapshot.completedPhotoIDs.count) completed"]
            if !snapshot.excludedPhotoIDs.isEmpty { parts.append("\(snapshot.excludedPhotoIDs.count) excluded") }
            if !snapshot.flaggedPhotoIDs.isEmpty { parts.append("\(snapshot.flaggedPhotoIDs.count) flagged") }
            if !snapshot.skippedPhotoIDs.isEmpty { parts.append("\(snapshot.skippedPhotoIDs.count) skipped") }
            if !snapshot.failedPhotoIDs.isEmpty { parts.append("\(snapshot.failedPhotoIDs.count) failed") }
            if !snapshot.unfinishedPhotoIDs.isEmpty { parts.append("\(snapshot.unfinishedPhotoIDs.count) unfinished") }
            return parts.joined(separator: " · ")
        }
        guard let summary else { return "" }
        var completed = 0, excluded = 0, failed = 0, flagged = 0, skipped = 0
        for result in summary.photos {
            if result.outcome?.hasPrefix("Skipped: excluded") == true { excluded += 1 }
            else if result.failed { failed += 1 }
            else if result.flagged != nil { flagged += 1 }
            else if result.outcome?.split(separator: "\n").contains(where: {
                $0.hasPrefix("Skipped:") || $0.hasPrefix("Edit skipped:") || $0.hasPrefix("Instruction skipped:") || $0 == "Model call limit reached."
            }) == true { skipped += 1 }
            else { completed += 1 }
        }
        var parts = ["\(completed) completed"]
        if excluded > 0 { parts.append("\(excluded) excluded") }
        if flagged > 0 { parts.append("\(flagged) flagged") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
    var plannedOperations: [String] {
        let actions = (draftPlan ?? plan)?.photoActions ?? []
        var operations: [String] = []
        let auto = actions.filter(\.auto).count
        let straightened = actions.filter { $0.straightenDegrees != nil }.count
        let flagged = actions.filter { $0.flagReason != nil }.count
        let closer = actions.filter(\.closerLook).count
        if auto > 0 { operations.append("Auto tone and colour · \(auto) photos") }
        if straightened > 0 { operations.append("Straighten · \(straightened) photos") }
        if flagged > 0 { operations.append("Flag misfires · \(flagged) photos") }
        if closer > 0 { operations.append("Closer review and edits · \(closer) photos") }
        return operations
    }
    var highlightedPhotos: Set<PhotoID> {
        if let question { return affectedPhotos(question) }
        if let plan, estimatedModelCalls != nil {
            return Set(plan.groups.filter { selectedGroup == nil || $0.id == selectedGroup }.flatMap(\.photos)).subtracting(excludedPhotos)
        }
        if let recentDecision { return affectedPhotos(recentDecision.question) }
        return []
    }

    /// The photos a question names, else its groups' photos. Straightening once highlighted every photo with a measured
    /// tilt: six beside "2 photos look tilted".
    func affectedPhotos(_ question: BatchQuestion) -> Set<PhotoID> {
        if let photos = question.photos { return Set(photos) }
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
        photoWindows = []
        var seen: Set<PhotoID> = []
        photos = found.filter { seen.insert($0).inserted }
        selectedPhotos = []
        states = Dictionary(uniqueKeysWithValues: photos.map { ($0, LibraryPhotoState()) })
        hasRun = false
        resetRun()
        total = photos.count
        status = photos.isEmpty ? "No JPEG, PNG, HEIC or RAW photos in this folder" : "\(photos.count) \(photos.count == 1 ? "photo" : "photos") ready"
    }

    func changeOutput(_ url: URL) async throws {
        guard !hasRun, let folder else { throw StudioScriptError.message("Choose the output before running.") }
        try await openFolder(folder, output: url)
    }

    func run() {
        run(using: nil)
    }

    /// The window and offline checks share this task lifetime, including cancellation after stream termination.
    func run(using models: StudioModels?) {
        guard canRun, runTask == nil else { return }
        runTask = Task {
            do { try await runLibrary(using: models) }
            catch { if !isCancellation(error) { issue = error.localizedDescription } }
            runTask = nil
        }
    }

    /// Uses the same batch agent for the window and scripted captures.
    func runLibrary(using suppliedModels: StudioModels? = nil, options suppliedOptions: BatchOptions? = nil,
                    allowKeychainInteraction: Bool = true,
                    onEvent: @MainActor (BatchEvent) async throws -> Void = { _ in }) async throws {
        guard canRun, let library, let folder else { throw StudioScriptError.message("Choose at least one photo before running.") }
        let targets = scopePhotos
        photoWindows.removeAll { $0.model == nil }
        let targetSet = Set(targets)
        guard photoWindows.allSatisfy({ window in
            guard let model = window.model, model.libraryLeaseID == leaseID, targetSet.contains(window.photo),
                  window.url == folder.appendingPathComponent(window.photo.rawValue),
                  window.opening || model.photoURL == window.url else { return true }
            return !window.opening && model.phase == .idle && !model.hasPendingLayerChanges
        }) else {
            throw StudioScriptError.message("Wait for the open photo's edit to finish before running this library.")
        }
        var options = suppliedOptions ?? BatchOptions(mode: mode, instruction: instruction, auto: auto,
            straighten: straighten.value, flagMisfires: flagMisfires, qualityThreshold: qualityThreshold)
        // Task-only guarded captures serialize photos so conservative in-flight
        // dollar reservations do not compete. Normal application defaults stay unchanged.
        let taskEnvironment = ProcessInfo.processInfo.environment
        if suppliedOptions == nil, taskEnvironment["LUMEN_TEST_BUDGET_LEDGER"] != nil,
           taskEnvironment["LUMEN_TEST_BUDGET_HELPER"] != nil { options.concurrency = 1 }
        resetRun()
        runTargets = targets
        runScope = scope
        runThreshold = options.qualityThreshold
        isRunning = true
        status = "Preparing the planner"
        defer {
            isRunning = false
            isStopping = false
            question = nil
            estimatedModelCalls = nil
            agent = nil
            scopedLibrary = nil
        }
        do {
            let models: StudioModels
            if let suppliedModels { models = suppliedModels }
            else { models = try await backends.models(allowKeychainInteraction: allowKeychainInteraction) }
            try Task.checkCancellation()
            guard !isStopping else { throw LumenError.cancelled }
            let scoped = try await ScopedStudioLibrary(base: library, targets: targets, folder: folder)
            scopedLibrary = scoped
            let agent = BatchAgent(host: scoped, reviewer: models.reviewer, planner: models.planner,
                                   segmenter: models.segmenter, generator: models.generator)
            self.agent = agent
            hasRun = true
            for try await event in await agent.run(options) {
                try Task.checkCancellation()
                receive(event)
                try await onEvent(event)
            }
            try Task.checkCancellation()
            guard !isStopping else { throw LumenError.cancelled }
            await refreshPhotoWindows()
        } catch {
            decisionTask?.cancel()
            recentDecision = nil
            stoppedSnapshot = await agent?.cancelAndWait()
            if stoppedSnapshot == nil {
                // Preparation can stop before an agent owns the targets. Keep
                // the frozen scope visible rather than losing its unfinished work.
                stoppedSnapshot = BatchSnapshot(summary: BatchSummary(photos: [], answers: [], modelCalls: 0, duration: 0, events: []),
                    completedPhotoIDs: [], excludedPhotoIDs: [], flaggedPhotoIDs: [], failedPhotoIDs: [], skippedPhotoIDs: [],
                    unfinishedPhotoIDs: targets, cancelled: isCancellation(error), settled: true, startedModelCalls: 0)
            }
            if let snapshot = stoppedSnapshot {
                totalCost = snapshot.summary.totalCost
                modelCalls = snapshot.startedModelCalls
                for result in snapshot.summary.photos { apply(result) }
                for photo in snapshot.unfinishedPhotoIDs {
                    states[photo]?.badges.insert(.unfinished)
                    refreshPhoto(photo)
                }
                done = snapshot.completedPhotoIDs.count + snapshot.excludedPhotoIDs.count + snapshot.flaggedPhotoIDs.count
                    + snapshot.failedPhotoIDs.count + snapshot.skippedPhotoIDs.count
            }
            await refreshPhotoWindows()
            status = (isCancellation(error) ? "Stopped" : "Library stopped") + (stoppedSnapshot == nil ? "" : " · \(completionDetail)")
            if !didMutate { hasRun = false }
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
        guard estimatedModelCalls != nil, !isStopping, let token = plan?.approvalToken, let agent else { return }
        let revision = draftRevision
        isCheckingApproval = true
        defer { isCheckingApproval = false }
        do {
            guard runScope == scope, runTargets == scopePhotos else {
                throw StudioScriptError.message("The photo scope changed. Discard this plan and plan again.")
            }
            try await scopedLibrary?.validateSources()
            guard revision == draftRevision, !isStopping else { return }
            let approval = BatchApproval(approvalToken: token, instructionOverrides: instructionOverrides,
                                         excludedPhotoIDs: runTargets.filter { excludedPhotos.contains($0) })
            let accepted = try await agent.approve(approval)
            draftPlan = accepted
            approvalIssue = nil
            estimatedModelCalls = nil
            selectedGroup = nil
            status = "Applying the plan"
        } catch {
            approvalIssue = error.localizedDescription
            status = "Plan needs to be checked again"
            if !(error is BatchApprovalError) {
                issue = error.localizedDescription
                stop()
            }
        }
    }

    func draftChanged() {
        draftRevision += 1
        let revision = draftRevision
        Task { await refreshDraft(revision: revision) }
    }

    func refreshDraft() async { await refreshDraft(revision: draftRevision) }

    private func refreshDraft(revision: Int) async {
        guard let token = plan?.approvalToken, estimatedModelCalls != nil, let agent, !isStopping else { return }
        do {
            let draft = try await agent.previewApproval(BatchApproval(approvalToken: token, instructionOverrides: instructionOverrides,
                                                                     excludedPhotoIDs: runTargets.filter { excludedPhotos.contains($0) }))
            guard revision == draftRevision, plan?.approvalToken == token else { return }
            draftPlan = draft
            approvalIssue = nil
        } catch {
            guard revision == draftRevision else { return }
            approvalIssue = error.localizedDescription
        }
    }

    func toggleSelection(_ photo: PhotoID) {
        guard !isRunning, photos.contains(photo) else { return }
        if selectedPhotos.contains(photo) { selectedPhotos.remove(photo) }
        else { selectedPhotos.insert(photo) }
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
        let url = folder.appendingPathComponent(photo.rawValue)
        let previousID = model.libraryLeaseID
        let previousLease = model.libraryIsEditing
        let window = LibraryPhotoWindow(model: model, photo: photo, url: url)
        photoWindows.append(window)
        model.libraryLeaseID = leaseID
        model.libraryIsEditing = { [weak self] in
            guard let self else { return false }
            return self.library === library && self.isRunning && self.runTargets.contains(photo)
        }
        defer { window.opening = false }
        do {
            let host = try await library.photoHost(photo)
            try await model.openLibraryPhoto(url, host: host, events: photoEvents[photo] ?? [])
        } catch {
            model.libraryLeaseID = previousID
            model.libraryIsEditing = previousLease
            photoWindows.removeAll { $0 === window }
            throw error
        }
    }

    private func refreshPhotoWindows() async {
        guard let folder else { return }
        for window in photoWindows {
            guard let model = window.model, model.libraryLeaseID == leaseID, runTargets.contains(window.photo),
                  model.photoURL == window.url, window.url == folder.appendingPathComponent(window.photo.rawValue) else { continue }
            await model.refreshLibraryResult()
        }
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
        var entryStatus: StepStatus?
        switch event {
        case .found(let count): total = count; title = "Measuring \(count) \(count == 1 ? "photo" : "photos")"; symbol = "viewfinder"
        case .measured(let photo, let facts):
            states[photo]?.facts = facts
            states[photo]?.badges.insert(.measured)
            status = "Measured \(photo.rawValue)"
        case .phase(let phase):
            // A pending provider answer is neither a finished trace nor a charge.
            status = phase.status
            return
        case .reviewed(let review):
            states[review.photo]?.review = review
            if review.quality < runThreshold { states[review.photo]?.badges.insert(.attention) }
            title = "Reviewed \(review.photo.rawValue)"; detail = review.description; symbol = "text.bubble"
        case .flagged(let photo, let reason):
            didMutate = true
            states[photo]?.badges.insert(.misfire)
            states[photo]?.badges.remove(.attention)
            states[photo]?.reason = reason
            title = "Flagged \(photo.rawValue)"; detail = reason; symbol = "flag"
        case .autoApplied(let photo, let label):
            didMutate = true
            states[photo]?.badges.insert(.auto); refreshPhoto(photo)
            title = "Auto · \(photo.rawValue)"; detail = label; symbol = "slider.horizontal.3"
        case .straightened(let photo, let degrees):
            didMutate = true
            states[photo]?.badges.insert(.straightened); refreshPhoto(photo)
            title = "Straightened \(photo.rawValue)"; detail = "\(degrees.formatted())°"; symbol = "rotate.left"
        case .planned(let plan): self.plan = plan; title = "Library plan"; detail = plan.summary; symbol = "list.bullet.indent"
        case .question(let question): self.question = question; reviewShown = true; title = question.question; symbol = "questionmark.bubble"
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
            draftPlan = plan; instructionOverrides = [:]; excludedPhotos = []; approvalIssue = nil; reviewShown = true
            title = "Ready for your approval"; detail = "About \(calls) more model calls" + (plan.estimatedCost.map { ", about " + studioDollars($0, estimated: true) + " USD" } ?? ""); symbol = "pause.circle"
        case .editStarted(let photo, let instruction):
            title = "Editing \(photo.rawValue)"; detail = instruction; symbol = "paintbrush.pointed"
        case .edit(let photo, let event):
            switch event {
            case .selected: break
            case .applied:
                didMutate = true
                states[photo]?.badges.insert(.edited); refreshPhoto(photo)
            case .reverted: didMutate = true; refreshPhoto(photo)
            default: photoEvents[photo, default: []].append(event)
            }
            if case .trace(let value) = event {
                trace = value; title = "\(photo.rawValue) · \(value.kind.rawValue.capitalized)"; detail = value.detail
                if value.kind == .failure { states[photo]?.badges.insert(.attention); states[photo]?.reason = value.detail }
            }
        case .editFinished(let result):
            apply(result); refreshPhoto(result.photo)
            title = result.failed ? "Needs attention · \(result.photo.rawValue)" : "Finished \(result.photo.rawValue)"
            detail = result.outcome
            if result.failed {
                symbol = "exclamationmark.triangle"
                entryStatus = .failed(result.outcome ?? "The edit needs review.")
            }
        case .progress(let done, let total): self.done = done; self.total = total
        case .finished(let summary):
            self.summary = summary; modelCalls = summary.modelCalls
            for result in summary.photos { apply(result); refreshPhoto(result.photo) }
            let hasFailures = summary.photos.contains(where: \.failed)
            title = (hasFailures ? "Finished with issues" : "Finished") + " · \(completionDetail)"
            symbol = hasFailures ? "exclamationmark.triangle" : "checkmark.seal"
            if hasFailures { entryStatus = .issues }
        case .trace(let value): trace = value; title = value.kind.rawValue.capitalized; detail = value.detail; symbol = "waveform.path"
        }
        if let trace {
            totalCost += trace.cost ?? 0
            if trace.model != nil { modelCalls += 1 }
        }
        if case .finished(let summary) = event { modelCalls = summary.modelCalls; totalCost = summary.totalCost }
        if let title {
            status = title
            events.append(StudioStep(title: title, symbol: symbol, detail: detail,
                                     status: entryStatus ?? (trace?.kind == .failure ? .failed(detail ?? "Failed") : .done),
                                     traces: trace.map { [$0] } ?? [], kind: .trace))
            if events.count > 80 { events.removeFirst(events.count - 80) }
        }
    }

    var timelineText: String {
        let lines = events.map { "\($0.title)\($0.detail.map { "\n" + $0 } ?? "")" }
        let choices = decisions.map { "\($0.question.question)\nDecided: \($0.answer)" }
        return (["Library: \(folder?.path ?? "")", "Instruction: \(instruction)", "Model calls: \(modelCalls)", "Cost: \(studioDollars(totalCost)) USD"] + choices + lines).joined(separator: "\n\n") + "\n"
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
        if result.outcome?.hasPrefix("Skipped: excluded") == true {
            states[result.photo]?.badges.remove(.attention)
            states[result.photo]?.badges.insert(.excluded)
        } else if result.outcome?.hasPrefix("Skipped:") == true { states[result.photo]?.badges.insert(.attention) }
    }

    private func resetRun() {
        decisionTask?.cancel()
        question = nil; recentDecision = nil; decisions = []; plan = nil; selectedGroup = nil
        estimatedModelCalls = nil; summary = nil; stoppedSnapshot = nil; events = []; photoEvents = [:]
        draftPlan = nil; instructionOverrides = [:]; excludedPhotos = []; approvalIssue = nil
        isCheckingApproval = false; draftRevision += 1; didMutate = false; runTargets = []
        done = 0; modelCalls = 0; totalCost = 0; issue = nil
    }

    private func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || error as? LumenError == .cancelled
    }
}
