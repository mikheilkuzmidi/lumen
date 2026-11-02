import AppKit
import Foundation
import LumenCore
import SwiftUI
import Testing
@testable import LumenStudio

@Suite("Studio library approval")
@MainActor
struct StudioLibraryApprovalTests {
    /// Opt-in snapshots of the real window and engine with offline test providers, for internal layout QA only.
    @Test func captureApprovalLayoutsWhenRequested() async throws {
        guard let destination = ProcessInfo.processInfo.environment["LUMEN_STUDIO_APPROVAL_CAPTURE_DIR"] else { return }
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Fixtures/library")
        let results = FileManager.default.temporaryDirectory.appendingPathComponent("studio-layout-results-\(UUID())")
        defer { try? FileManager.default.removeItem(at: results) }
        let model = StudioLibraryModel()
        try await model.openFolder(folder, output: results)
        model.mode = .planFirst
        model.instruction = "Make everyone's T-shirts blue"
        model.straighten = .yes
        model.qualityThreshold = 0
        let planner = ApprovalRecordingPlanner()
        let models = StudioModels(planner: planner, segmenter: SnapshotSegmenter(), generator: SnapshotGenerator(),
                                  reviewer: LibraryReviewer())
        let sizes = [NSSize(width: 980, height: 680), NSSize(width: 1440, height: 900)]
        func capture(_ stage: String, showing shownModel: StudioLibraryModel? = nil) async throws {
            for size in sizes {
                let view = NSHostingView(rootView: StudioLibraryView(model: shownModel ?? model, activatesBackend: false)
                    .frame(width: size.width, height: size.height))
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.isReleasedWhenClosed = false
                panel.contentView = view
                StudioScriptApplication.show(panel, visible: false)
                defer { panel.orderOut(nil) }
                try await Task.sleep(for: stage == "06-editing" || stage == "07-completed" ? .seconds(2) : .milliseconds(220))
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("\(stage)-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
        try await capture("01-request")
        var capturedEditing = false
        try await model.runLibrary(using: models) { event in
            switch event {
            case .question(let question):
                try await capture("02-question")
                await model.answer(question.options[question.recommended])
            case .awaitingApproval(let plan, _):
                try await capture("03-plan")
                let group = try #require(plan.groups.first)
                model.instructionOverrides[group.id] = "Make the T-shirts a deep forest green, keeping the original fabric and lighting"
                model.excludedPhotos = [try #require(model.photos.first)]
                await model.refreshDraft()
                try await capture("04-edited-draft")
                model.reviewShown = false
                try await capture("05-collapsed")
                model.reviewShown = true
                await model.approve()
            case .editStarted where !capturedEditing:
                capturedEditing = true
                try await capture("06-editing")
            default: break
            }
        }
        try await capture("07-completed")
        #expect(await planner.instructions.allSatisfy { $0.contains("deep forest green") })
        #expect(model.summary != nil)
        let stopped = StudioLibraryModel()
        try await stopped.openFolder(folder, output: results.appendingPathComponent("stopped"))
        stopped.instruction = "Make everyone's T-shirts blue"
        stopped.mode = .planFirst
        stopped.straighten = .no
        await #expect(throws: LumenError.cancelled) {
            try await stopped.runLibrary(using: models) { event in
                if case .question(let question) = event { await stopped.answer(question.options[question.recommended]) }
                if case .awaitingApproval = event { stopped.stop() }
            }
        }
        #expect(stopped.stoppedSnapshot?.unfinishedPhotoIDs.count == 16)
        try await capture("08-stopped", showing: stopped)
        try "Internal visual QA. These screenshots render the real Studio UI and actual batch engine using deterministic offline test providers and CC0 fixtures. They are not evidence of a live Meta response and must not substitute for final product footage.\n"
            .write(to: output.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    @Test func selectedScopeChangesOnlyThosePhotosAndRunsTheEditedDraft() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.scope = .selected
        #expect(!model.canRun)
        model.toggleSelection(fixture.photos[1])
        #expect(model.scopePhotos == [fixture.photos[1]])
        let planner = ApprovalRecordingPlanner()
        let supplied = fixture.models()
        let models = StudioModels(planner: planner, segmenter: supplied.segmenter, generator: supplied.generator,
                                  reviewer: LibraryReviewer())
        model.mode = .planFirst
        model.instruction = "Make their shirts blue"
        model.straighten = .yes
        try await model.runLibrary(using: models) { event in
            if case .question(let question) = event { await model.answer(question.options[question.recommended]) }
            if case .awaitingApproval(let plan, _) = event {
                #expect(plan.targetPhotos == [fixture.photos[1]])
                #expect(model.runTargets == [fixture.photos[1]])
                #expect(model.plannedOperations.contains("Auto tone and colour · 1 photos"))
                #expect(model.plannedOperations.contains("Straighten · 1 photos"))
                model.instructionOverrides = ["people": "Make the shirt green"]
                await model.refreshDraft()
                #expect(model.draftPlan?.groups.first?.instruction == "Make the shirt green")
                #expect(await fixture.host.autoCount == 0)
                await model.approve()
            }
        }
        #expect(await planner.instructions == ["Make the shirt green"])
        #expect(await fixture.host.autoCount == 1)
        #expect(await fixture.host.saved == [fixture.photos[1]])
        #expect(model.summary?.photos.map(\.photo) == [fixture.photos[1]])
    }

    @Test func currentViewAndEntireLibraryHaveHonestIdenticalFolderCounts() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.scope = .currentView
        #expect(model.scopePhotos == fixture.photos)
        model.scope = .entireLibrary
        #expect(model.scopePhotos == fixture.photos)
    }

    @Test func budgetLimitedPhotosAreShownAsSkippedRatherThanCompleted() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        try await model.runLibrary(using: fixture.models(), options: BatchOptions(mode: .autonomous, instruction: "Warm it",
            auto: false, straighten: false, qualityThreshold: 0, maxModelCalls: 0))
        #expect(model.completionDetail == "0 completed · 2 skipped")
    }

    @Test func theWindowsRunAndStopKeepASettledCancellationSnapshot() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.mode = .planFirst
        model.straighten = .no
        model.run(using: fixture.models())
        for _ in 0..<200 {
            if model.estimatedModelCalls != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.estimatedModelCalls != nil)
        model.stop()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isRunning)
        #expect(model.stoppedSnapshot?.settled == true)
        #expect(model.stoppedSnapshot?.cancelled == true)
        #expect(model.completionDetail == "0 completed · 2 unfinished")
        #expect(model.done == 0)
        #expect(model.summary == nil)
        #expect(model.status == "Stopped · 0 completed · 2 unfinished")
        #expect(await fixture.host.autoCount == 0)
        #expect(await fixture.host.saved.isEmpty)
        await model.close()
    }

    @Test func cancellationDuringPreparationKeepsEveryFrozenTargetUnfinished() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        let models = fixture.models()
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await model.runLibrary(using: models)
                Issue.record("Cancelled preparation unexpectedly completed")
            } catch {
                #expect(error is CancellationError)
            }
        }.value
        #expect(model.stoppedSnapshot?.settled == true)
        #expect(model.stoppedSnapshot?.cancelled == true)
        #expect(model.stoppedSnapshot?.unfinishedPhotoIDs == fixture.photos)
        #expect(model.done == 0)
        #expect(model.completionDetail == "0 completed · 2 unfinished")
        #expect(await fixture.host.autoCount == 0)
        #expect(await fixture.host.saved.isEmpty)
    }

    @Test func exclusionPreventsAutoStraightenEditAndSaveAndUpdatesPreview() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.mode = .planFirst
        model.instruction = "Make it blue"
        model.straighten = .yes
        try await model.runLibrary(using: fixture.models()) { event in
            if case .awaitingApproval = event {
                model.excludedPhotos = [fixture.photos[0]]
                await model.refreshDraft()
                #expect(model.draftPlan?.groups.flatMap(\.photos) == [fixture.photos[1]])
                #expect(model.draftPlan?.photoActions?.map(\.photo) == [fixture.photos[1]])
                #expect(model.highlightedPhotos == [fixture.photos[1]])
                await model.approve()
            }
        }
        #expect(await fixture.host.autoCount == 1)
        #expect(await fixture.host.rotations == [fixture.photos[1]: -2])
        #expect(await fixture.host.saved == [fixture.photos[1]])
        let excluded = try #require(model.summary?.photos.first)
        #expect(excluded.instruction == nil && excluded.auto == nil && excluded.straightened == nil)
        #expect(excluded.outcome?.hasPrefix("Skipped: excluded") == true)
        #expect(model.states[fixture.photos[0]]?.badges.contains(.excluded) == true)
        #expect(model.states[fixture.photos[0]]?.badges.contains(.attention) == false)
        #expect(model.completionDetail == "1 completed · 1 excluded")
    }

    @Test func changingTheSelectedScopeInvalidatesApprovalBeforeAnyMutation() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.scope = .selected
        model.selectedPhotos = [fixture.photos[0]]
        model.mode = .planFirst
        model.straighten = .no
        await #expect(throws: LumenError.cancelled) {
            try await model.runLibrary(using: fixture.models()) { event in
                if case .awaitingApproval = event {
                    model.selectedPhotos = Set(fixture.photos)
                    await model.approve()
                }
            }
        }
        #expect(model.issue?.contains("scope changed") == true)
        #expect(await fixture.host.autoCount == 0)
        #expect(await fixture.host.saved.isEmpty)
        #expect(model.canRun)
    }

    @Test func changingASourceFileInvalidatesApprovalBeforeAnyMutation() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.mode = .planFirst
        model.straighten = .no
        await #expect(throws: LumenError.cancelled) {
            try await model.runLibrary(using: fixture.models()) { event in
                if case .awaitingApproval = event {
                    let source = fixture.folder.appendingPathComponent(fixture.photos[0].rawValue)
                    var changed = try Data(contentsOf: source)
                    changed.append(0)
                    try changed.write(to: source)
                    await model.approve()
                }
            }
        }
        #expect(model.issue?.contains("source photo changed") == true)
        #expect(await fixture.host.autoCount == 0)
        #expect(await fixture.host.saved.isEmpty)
    }

    @Test func changingAnOpenPhotosLayersInvalidatesApproval() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        let editor = StudioModel(makePhoto: { try LibraryTestPhoto(url: $0) })
        try await model.openPhoto(fixture.photos[0], in: editor)
        model.mode = .planFirst
        model.straighten = .no
        await #expect(throws: LumenError.cancelled) {
            try await model.runLibrary(using: fixture.models()) { event in
                if case .awaitingApproval = event {
                    let photo = try #require(await fixture.host.editHost(fixture.photos[0]) as? LibraryTestPhoto)
                    try await photo.apply(Layer(label: "Manual change", content: .adjustment(values: [.exposure: 0.2], mask: nil)), assets: AssetStore())
                    await model.approve()
                }
            }
        }
        #expect(model.issue?.contains("edits to one.png changed") == true)
        #expect(await fixture.host.autoCount == 0)
        #expect(await fixture.host.saved.isEmpty)
    }

    @Test func alreadyOpenPhotoWindowIsReadOnlyBeforeAndAfterApprovalAndRefreshesItsUndoHistory() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let library = fixture.model()
        try await library.openFolder(fixture.folder)
        let photo = try #require(try await fixture.host.editHost(fixture.photos[0]) as? LibraryTestPhoto)
        let original = Layer(label: "Existing edit", content: .adjustment(values: [.exposure: 0.2], mask: nil))
        try await photo.apply(original, assets: AssetStore())
        let editor = StudioModel(makePhoto: { try LibraryTestPhoto(url: $0) })
        try await library.openPhoto(fixture.photos[0], in: editor)
        editor.prompt = "A separate instruction"
        #expect(editor.canUndo && editor.canRun)
        editor.setOpacity(0.4, for: original.id)
        await #expect(throws: (any Error).self) {
            try await library.runLibrary(using: fixture.models(), options: BatchOptions(mode: .autonomous, auto: false,
                                                                                      straighten: false, qualityThreshold: 0))
        }
        #expect(!library.isRunning)
        editor.setOpacity(1, for: original.id)
        editor.commitLayerChanges()
        library.mode = .planFirst
        library.instruction = "Warm it"
        library.auto = false
        library.straighten = .no
        var checkedAfterApproval = false
        try await library.runLibrary(using: fixture.models()) { event in
            if case .awaitingApproval = event {
                #expect(editor.isLibraryReadOnly && editor.isBusy)
                #expect(!editor.canUndo && !editor.canRedo && !editor.canRun && !editor.canExport)
                editor.toggleLayer(original.id)
                editor.setOpacity(0.1, for: original.id)
                editor.commitLayerChanges()
                editor.undo(); editor.redo(); editor.toggleStraightening()
                #expect(editor.layers == [original])
                await #expect(throws: (any Error).self) { try await editor.runEdit(using: fixture.models()) }
                await library.approve()
            }
            if case .editStarted = event {
                checkedAfterApproval = true
                #expect(editor.isLibraryReadOnly && !editor.canUndo)
                editor.toggleLayer(original.id)
                editor.setOpacity(0.2, for: original.id)
                editor.commitLayerChanges()
                editor.undo(); editor.redo()
                #expect(editor.layers == [original])
            }
        }
        #expect(checkedAfterApproval)
        let final = await photo.layers
        #expect(final.count == 2)
        #expect(final.first == original)
        #expect(editor.layers == final)
        #expect(!editor.isLibraryReadOnly && editor.canUndo)
        editor.undo()
        for _ in 0..<200 where editor.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await photo.layers == [original])
        editor.redo()
        for _ in 0..<200 where editor.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await photo.layers == final)
    }

    @Test func libraryCannotStartWhileAnAlreadyOpenTargetHasAnActiveEdit() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let library = fixture.model()
        try await library.openFolder(fixture.folder)
        let editor = StudioModel(makePhoto: { try LibraryTestPhoto(url: $0) })
        try await library.openPhoto(fixture.photos[0], in: editor)
        editor.prompt = "Warm it"
        let gate = WindowLeaseGate()
        let supplied = fixture.models()
        let models = StudioModels(planner: WindowLeasePlanner(gate: gate), segmenter: supplied.segmenter,
                                  generator: supplied.generator)
        let editing = Task { try await editor.runEdit(using: models) }
        await gate.waitUntilEntered()
        #expect(editor.phase == .running)
        await #expect(throws: (any Error).self) {
            try await library.runLibrary(using: fixture.models(), options: BatchOptions(mode: .autonomous, auto: false,
                                                                                      straighten: false, qualityThreshold: 0))
        }
        #expect(!library.isRunning)
        #expect(await fixture.host.saved.isEmpty)
        await gate.release()
        try await editing.value
        try await library.runLibrary(using: fixture.models(), options: BatchOptions(mode: .autonomous, auto: false,
                                                                                  straighten: false, qualityThreshold: 0))
        #expect(library.summary != nil)
    }

    @Test func invalidInstructionCanBeCorrectedWithoutCancellingThePlan() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.mode = .planFirst
        model.instruction = "Warm it"
        model.straighten = .no
        try await model.runLibrary(using: fixture.models()) { event in
            if case .awaitingApproval = event {
                model.instructionOverrides = ["library": " "]
                await model.refreshDraft()
                #expect(model.approvalIssue?.contains("cannot be blank") == true)
                await model.approve()
                #expect(!model.isStopping)
                #expect(await fixture.host.autoCount == 0)
                model.instructionOverrides = ["library": "Make it warmer"]
                await model.refreshDraft()
                #expect(model.approvalIssue == nil)
                await model.approve()
            }
        }
        #expect(model.summary?.photos.count == 2)
    }
}

private actor ApprovalRecordingPlanner: Planner {
    let modelID = "recorded-instruction-test"
    private(set) var instructions: [String] = []
    func plan(_ request: PlanRequest) async throws -> EditPlan {
        instructions.append(request.instruction)
        return EditPlan(summary: request.instruction, steps: [.adjust(Adjustment(values: [.saturation: 5]))])
    }
    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Done") }
}

private struct SnapshotSegmenter: Segmenter {
    let modelID = "offline-layout-segmenter"
    func segment(_ request: SegmentRequest) async throws -> [Segment] { [] }
}

private struct SnapshotGenerator: Generator {
    let modelID = "offline-layout-generator"
    func generate(_ request: GenerateRequest) async throws -> EncodedImage { request.image }
}

private actor WindowLeaseGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var paused: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        await withCheckedContinuation { paused = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    func release() { paused?.resume(); paused = nil }
}

private struct WindowLeasePlanner: Planner {
    let gate: WindowLeaseGate
    let modelID = "offline-window-lease"
    func plan(_ request: PlanRequest) async throws -> EditPlan {
        await gate.pause()
        return EditPlan(summary: "Warm it", steps: [.adjust(Adjustment(values: [.temperature: 5]))])
    }
    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Done") }
}
