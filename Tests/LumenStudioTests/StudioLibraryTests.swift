import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import LumenRender
import Testing
import UniformTypeIdentifiers
@testable import LumenStudio

@Suite("Studio library")
@MainActor
struct StudioLibraryTests {
    @Test func mapsEventsToBadgesAndKeepsLatestEventsBounded() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        #expect(model.output == fixture.folder.appendingPathComponent("Lumen", isDirectory: true))
        let photo = fixture.photos[0]
        model.receive(.measured(photo, LibraryFixture.facts))
        model.receive(.reviewed(PhotoReview(photo: photo, misfire: false, quality: 0.1, description: "Soft portrait", group: "people", matchesInstruction: true)))
        #expect(model.states[photo]?.badges == [.measured, .attention])
        model.receive(.autoApplied(photo, label: "Auto: exposure +0.2"))
        model.receive(.straightened(photo, degrees: -2))
        model.receive(.edit(photo, .applied(Layer(label: "Shirt", content: .adjustment(values: [.saturation: 10], mask: nil)))))
        #expect(model.states[photo]?.badges == [.measured, .attention, .auto, .straightened, .edited])
        model.receive(.flagged(photo, reason: "Closed eyes"))
        #expect(model.states[photo]?.badges.contains(.misfire) == true)
        #expect(model.states[photo]?.badges.contains(.attention) == false)
        #expect(model.states[photo]?.reason == "Closed eyes")
        model.receive(.editFinished(BatchPhotoResult(photo: photo, outcome: "Unreadable patch", failed: true)))
        #expect(model.states[photo]?.badges.contains(.failed) == true)
        #expect(model.states[photo]?.reason == "Unreadable patch")
        for _ in 0..<100 { model.receive(.autoApplied(photo, label: "Auto")) }
        #expect(model.events.count == 80)
    }

    @Test(arguments: BatchMode.allCases)
    func handlesQuestionsAndApprovalInEveryMode(mode: BatchMode) async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let reviewer = LibraryReviewer()
        try await model.openFolder(fixture.folder)
        model.mode = mode
        model.instruction = "Make their shirts blue"
        model.straighten = .ask
        var asked: [String] = []
        var approvals = 0
        try await model.runLibrary(using: fixture.models(reviewer: reviewer)) { event in
            switch event {
            case .question(let question):
                asked.append(question.id)
                #expect(mode != .autonomous)
                #expect(model.question == question)
                #expect(model.highlightedPhotos == Set(fixture.photos))
                await model.answer("Not an option")
                #expect(model.question == question)
                await model.answer(question.options[question.recommended])
            case .answered(let answer):
                #expect(answer.byPerson == (mode != .autonomous))
                #expect(model.recentDecision == answer)
                #expect(model.decisions.contains(answer))
            case .awaitingApproval(let plan, let calls):
                approvals += 1
                #expect(mode == .planFirst && calls > 0)
                #expect(model.plan == plan && model.estimatedModelCalls == calls)
                #expect(await fixture.host.autoCount == 0)
                model.selectedGroup = "people"
                #expect(model.highlightedPhotos == Set(fixture.photos))
                await model.approve()
            default: break
            }
        }
        #expect(asked == (mode == .autonomous ? [] : ["straighten", "style"]))
        #expect(approvals == (mode == .planFirst ? 1 : 0))
        #expect(model.summary?.photos.count == 2)
        #expect(model.done == 2 && model.total == 2)
        #expect(model.modelCalls == model.summary?.modelCalls)
        #expect(model.modelCalls == 7)
        #expect(model.question == nil && model.estimatedModelCalls == nil && !model.isRunning)
        #expect(await fixture.host.autoCount == 2)
        #expect(await reviewer.answers.last?["style"] == "Keep each style")
        for photo in fixture.photos {
            #expect(model.states[photo]?.badges.isSuperset(of: [.measured, .auto, .straightened, .edited]) == true)
        }
    }

    @Test func cancelAtApprovalLeavesThePhotosUntouched() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.mode = .planFirst
        model.straighten = .no
        await #expect(throws: LumenError.cancelled) {
            try await model.runLibrary(using: fixture.models()) { event in
                if case .awaitingApproval = event { model.stop() }
            }
        }
        #expect(await fixture.host.autoCount == 0)
        #expect(await fixture.host.saved.isEmpty)
        #expect(model.status == "Stopped" && !model.isRunning)
        #expect(model.estimatedModelCalls == nil && model.summary == nil)
    }

    @Test func selectingAPlanGroupHighlightsItsPhotosAfterAQuestion() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        let question = BatchQuestion(id: "style", question: "Which style?", options: ["Same", "Each"], recommended: 1, groups: ["first"])
        let plan = BatchPlan(summary: "Two scenes", groups: [
            BatchGroup(id: "first", title: "First scene", photos: [fixture.photos[0]], instruction: "Blue shirts"),
            BatchGroup(id: "second", title: "Second scene", photos: [fixture.photos[1]], instruction: "Navy shirts"),
        ])
        model.receive(.planned(plan))
        model.receive(.question(question))
        #expect(model.highlightedPhotos == [fixture.photos[0]])
        model.receive(.answered(BatchAnswer(question: question, answer: "Each", byPerson: true)))
        model.receive(.awaitingApproval(plan, estimatedModelCalls: 10))
        model.selectedGroup = "second"
        #expect(model.highlightedPhotos == [fixture.photos[1]])
    }

    @Test func givesLowQualityPhotosACloserLookAndClearsAttentionAfterSuccess() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.straighten = .no
        var closerLooks = 0
        try await model.runLibrary(using: fixture.models(reviewer: LibraryReviewer(quality: 0.2))) { event in
            if case .editStarted(let photo, let instruction) = event {
                closerLooks += 1
                #expect(instruction.contains("Improve this photo naturally"))
                #expect(model.states[photo]?.badges.contains(.attention) == true)
            }
        }
        #expect(closerLooks == 2)
        #expect(model.states.values.allSatisfy { $0.badges.contains(.edited) && !$0.badges.contains(.attention) })
    }

    @Test func opensTheSameDocumentAndRestoresPatchAssetsOnUndoAndRedo() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.instruction = "Lighten the shirts"
        model.straighten = .yes
        try await model.runLibrary(using: fixture.models(patch: true))
        let photo = fixture.photos[0]
        let document = try #require(try await fixture.host.editHost(photo) as? LibraryTestPhoto)
        let originalLayers = await document.layers
        #expect(originalLayers.count == 2)
        let editor = StudioModel(makePhoto: { try LibraryTestPhoto(url: $0) })
        try await model.openPhoto(photo, in: editor)
        #expect(editor.layers == originalLayers)
        #expect(editor.sidebar == .layers && editor.canUndo && editor.preview != nil && editor.original != nil)
        #expect(editor.straighteningAngle == -2 && editor.batchStraightening == -2)
        editor.toggleStraightening()
        await waitForEditor(editor)
        #expect(await document.straighteningAngle == 0)
        editor.undo()
        await waitForEditor(editor)
        #expect(await document.straighteningAngle == -2)
        #expect(editor.steps.contains { $0.title == "Edit finished" })
        editor.toggleLayer(originalLayers[1].id)
        await waitForEditor(editor)
        #expect(await document.layers.last?.isEnabled == false)
        editor.undo()
        await waitForEditor(editor)
        #expect(await document.layers == originalLayers)
        editor.undo()
        await waitForEditor(editor)
        #expect(await document.layers.count == 1)
        editor.redo()
        await waitForEditor(editor)
        #expect(await document.layers == originalLayers)
        #expect(editor.issue == nil)
        let output = fixture.folder.appendingPathComponent("export.jpg")
        try await editor.exportPhoto(to: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func honoursBasePassOptionsAndMarksLowQualityPhotosForAttention() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.auto = false
        model.straighten = .no
        model.flagMisfires = false
        model.qualityThreshold = 0
        try await model.runLibrary(using: fixture.models())
        #expect(await fixture.host.autoCount == 0)
        #expect(await fixture.host.rotations.isEmpty)
        #expect(model.decisions.isEmpty)
        #expect(model.modelCalls == 0)
        #expect(model.states.values.allSatisfy { $0.badges == [.measured] })
    }

    @Test func flagsMisfiresAndContinuesPastOneFailedPhoto() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        await fixture.host.fail(fixture.photos[0])
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        model.straighten = .no
        try await model.runLibrary(using: fixture.models(reviewer: LibraryReviewer(misfire: true)))
        #expect(model.states[fixture.photos[0]]?.badges.contains(.failed) == true)
        #expect(model.states[fixture.photos[1]]?.badges.contains(.misfire) == true)
        #expect(model.states[fixture.photos[1]]?.reason == "Closed eyes")
        #expect(model.summary?.photos.first?.failed == true)
        #expect(model.done == 2)
    }

    @Test func changesOutputOnlyBeforeTheRun() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await model.openFolder(fixture.folder)
        let output = fixture.folder.appendingPathComponent("Results")
        try await model.changeOutput(output)
        #expect(model.output == output)
        model.straighten = .no
        try await model.runLibrary(using: fixture.models())
        await #expect(throws: (any Error).self) { try await model.changeOutput(fixture.folder) }
    }

    private func waitForEditor(_ model: StudioModel) async {
        for _ in 0..<200 where model.isBusy { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isBusy)
    }
}

struct LibraryFixture {
    let folder: URL
    let photos: [PhotoID]
    let host: LibraryTestHost
    static let facts = PhotoFacts(size: PixelSize(width: 32, height: 24), sharpness: 0.8, exposure: 0.5, tilt: 2, verticalLean: 2)

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photos = [PhotoID("one.png"), PhotoID("two.png")]
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        for photo in photos {
            let destination = try #require(CGImageDestinationCreateWithURL(folder.appendingPathComponent(photo.rawValue) as CFURL,
                UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        host = try LibraryTestHost(folder: folder, photos: photos)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
    @MainActor func model() -> StudioLibraryModel { StudioLibraryModel(makeLibrary: { _, _ in host }) }
    func models(reviewer: (any BatchPlanner)? = nil, patch: Bool = false) -> StudioModels {
        StudioModels(planner: LibraryPhotoPlanner(patch: patch), segmenter: LibrarySegmenter(), generator: LibraryGenerator(), reviewer: reviewer)
    }
}

actor LibraryTestHost: LibraryHost {
    let ids: [PhotoID]
    let documents: [PhotoID: LibraryTestPhoto]
    private(set) var autoCount = 0
    private(set) var rotations: [PhotoID: Double] = [:]
    private(set) var saved: [PhotoID] = []
    private var failure: PhotoID?
    init(folder: URL, photos: [PhotoID]) throws {
        ids = photos
        documents = try Dictionary(uniqueKeysWithValues: photos.map { ($0, try LibraryTestPhoto(url: folder.appendingPathComponent($0.rawValue))) })
    }
    func fail(_ photo: PhotoID) { failure = photo }
    func photos() async throws -> [PhotoID] { ids }
    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage { try await documents[photo]!.render(maxLongEdge: maxLongEdge) }
    func facts(_ photo: PhotoID) async throws -> PhotoFacts {
        if photo == failure { throw LumenError.invalidResponse("Unreadable photo") }
        return LibraryFixture.facts
    }
    func applyAuto(_ photo: PhotoID) async throws -> String {
        autoCount += 1
        try await documents[photo]!.apply(Layer(label: "Auto", content: .adjustment(values: [.exposure: 0.1], mask: nil)), assets: AssetStore())
        return "Auto"
    }
    func straighten(_ photo: PhotoID, degrees: Double) async throws {
        rotations[photo] = degrees
        await documents[photo]!.straighten(degrees: degrees)
    }
    func flag(_ photo: PhotoID, reason: String) async throws {}
    func editHost(_ photo: PhotoID) async throws -> any EditHost { documents[photo]! }
    func save(_ photo: PhotoID) async throws { saved.append(photo) }
}

actor LibraryReviewer: BatchPlanner {
    nonisolated let modelID = "recorded-library-reviewer"
    let misfire: Bool
    let quality: Double
    private(set) var answers: [[String: String]] = []
    init(misfire: Bool = false, quality: Double = 0.8) { self.misfire = misfire; self.quality = quality }
    func review(_ request: ReviewRequest) async throws -> [PhotoReview] {
        request.photos.map { PhotoReview(photo: $0.photo, misfire: misfire, misfireReason: misfire ? "Closed eyes" : nil,
            quality: quality, description: "Friends outdoors", group: "people", matchesInstruction: true) }
    }
    func plan(_ request: BatchPlanRequest) async throws -> BatchPlan {
        answers.append(request.answers)
        return BatchPlan(summary: "Make the shirts blue", groups: [BatchGroup(id: "people", title: "Friends",
            photos: request.reviews.map(\.photo), instruction: "Make the shirt blue")], questions: request.answers["style"] == nil ? [
                BatchQuestion(id: "style", question: "Same shirt, or keep each style?", options: ["Same shirt", "Keep each style"], recommended: 1, groups: ["people"]),
            ] : [])
    }
}

private struct LibraryPhotoPlanner: Planner {
    let modelID = "recorded-photo-planner"
    let patch: Bool
    func plan(_ request: PlanRequest) async throws -> EditPlan {
        let steps: [EditStep] = patch ? [.select(Selection(id: "shirt", concept: "shirt")),
            .regenerate(Regeneration(region: "shirt", prompt: "A blue shirt"))] : [.adjust(Adjustment(values: [.saturation: 5]))]
        return EditPlan(summary: "Change the shirt", steps: steps)
    }
    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Done") }
}
private struct LibrarySegmenter: Segmenter {
    let modelID = "recorded-segmenter"
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        [Segment(label: "shirt", box: .whole, mask: MaskData(size: request.image.size, filledWith: 255))]
    }
}
private struct LibraryGenerator: Generator {
    let modelID = "recorded-generator"
    func generate(_ request: GenerateRequest) async throws -> EncodedImage { request.image }
}

actor LibraryTestPhoto: StudioStraighteningPhoto {
    private let image: EncodedImage
    private(set) var layers: [Layer] = []
    private(set) var straighteningAngle: Double = 0
    func straighten(degrees: Double) { straighteningAngle = degrees }

    init(url: URL) throws {
        image = EncodedImage(data: try Data(contentsOf: url), format: .png, size: PixelSize(width: 32, height: 24))
    }
    func size() async -> PixelSize { image.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { image }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage { image }
    func apply(_ layer: Layer, assets: AssetStore) async throws {
        switch layer.content {
        case .patch(let image, let mask, _):
            guard case .image = await assets.get(image), case .mask = await assets.get(mask) else {
                throw LumenError.invalidResponse("The patch's assets were not retained.")
            }
        case .adjustment(_, let mask?):
            guard case .mask = await assets.get(mask) else { throw LumenError.invalidResponse("The mask was not retained.") }
        default: break
        }
        if let index = layers.firstIndex(where: { $0.id == layer.id }) { layers[index] = layer }
        else { layers.append(layer) }
    }
    func remove(_ layer: Layer.ID) async throws { layers.removeAll { $0.id == layer } }
    func export(to url: URL, format: EncodedImage.Format) async throws {
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let type = format == .png ? UTType.png : UTType.jpeg
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
