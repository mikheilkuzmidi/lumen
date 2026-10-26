import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenStudio

@Suite("Studio model")
@MainActor
struct StudioModelTests {
    @Test func runsEveryScriptMilestoneWithoutLaunchingTheApp() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try makePhoto(in: folder)
        let script = try makeScript(photo: photo, area: true)
        let model = StudioModel(makePhoto: { try StudioTestPhoto(url: $0) })
        let planner = StudioPlanner()
        let models = StudioModels(planner: planner, segmenter: StudioSegmenter(), generator: StudioGenerator())
        let runner = StudioScriptRunner(model: model, script: script, scriptURL: folder.appendingPathComponent("edit.json"), output: folder)
        var snapshots: [StudioSnapshot] = []
        try await runner.run(using: models) { snapshot in
            snapshots.append(snapshot)
            switch snapshot {
            case .opened:
                #expect(model.preview != nil && model.area == nil)
            case .area:
                #expect(model.area == script.area)
            case .planned:
                #expect(model.planSummary == "Turn the jacket yellow")
                #expect(model.steps.contains { $0.title == "Redraw jacket" })
            case .selected:
                #expect(model.regions.count == 1)
                #expect(model.regions.first?.name == "jacket")
            case .redrawn:
                #expect(model.layers.count == 1 && model.preview != nil)
                #expect(model.regions.isEmpty)
            case .finished:
                #expect(model.completion == "The jacket is yellow")
                #expect(model.phase == .idle)
            case .compare:
                #expect(model.showsOriginal && model.original != nil)
            case .layers:
                #expect(!model.showsOriginal && model.sidebar == .layers)
            }
        }
        #expect(snapshots == StudioSnapshot.allCases)
        #expect(model.phase == .idle && model.canUndo && model.canExport)
        #expect(await planner.requestedArea == script.area)
        let result = folder.appendingPathComponent("result.jpg")
        let image = try #require(CGImageSourceCreateWithURL(result as CFURL, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(pixels.width == 32 && pixels.height == 24)
        let timeline = try String(contentsOf: folder.appendingPathComponent("timeline.txt"), encoding: .utf8)
        #expect(timeline.contains("Keep the jacket folds and make it bright yellow"))
        #expect(timeline.contains("The jacket is yellow"))
        #expect(timeline.contains("[Done] Redraw jacket"))
    }

    @Test func omitsMilestonesThatNeverOccur() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try makePhoto(in: folder)
        let script = try makeScript(photo: photo, area: false)
        let runner = StudioScriptRunner(model: StudioModel(makePhoto: { try StudioTestPhoto(url: $0) }), script: script,
                                        scriptURL: folder.appendingPathComponent("edit.json"), output: folder)
        let models = StudioModels(planner: StudioPlanner(steps: [.finish(Finish(reason: "Already done"))]),
                                  segmenter: StudioSegmenter(), generator: StudioGenerator())
        var snapshots: [StudioSnapshot] = []
        try await runner.run(using: models) { snapshots.append($0) }
        #expect(snapshots == [.opened, .planned, .finished, .compare, .layers])
    }

    @Test func reportsModelFailuresAndKeepsTheTimeline() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try makePhoto(in: folder)
        let script = try makeScript(photo: photo, area: false)
        let model = StudioModel(makePhoto: { try StudioTestPhoto(url: $0) })
        let runner = StudioScriptRunner(model: model, script: script,
                                        scriptURL: folder.appendingPathComponent("edit.json"), output: folder)
        let models = StudioModels(planner: StudioPlanner(fails: true), segmenter: StudioSegmenter(), generator: StudioGenerator())
        await #expect(throws: (any Error).self) { try await runner.run(using: models) { _ in } }
        #expect(model.phase == .idle)
        #expect(model.issue?.contains("recorded failure") == true)
        let timeline = try String(contentsOf: folder.appendingPathComponent("timeline.txt"), encoding: .utf8)
        #expect(timeline.contains("recorded failure"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.jpg").path))
    }

    @Test func keepsTheMaskWhileTheNextStepRuns() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(makePhoto: { try StudioTestPhoto(url: $0) })
        try await model.openPhoto(makePhoto(in: folder))
        model.prompt = "Make the jacket yellow"
        let models = StudioModels(planner: StudioPlanner(), segmenter: StudioSegmenter(), generator: StudioGenerator())
        var sawRedraw = false
        try await model.runEdit(using: models) { event in
            if case .stepStarted(_, .regenerate) = event {
                sawRedraw = true
                #expect(model.regions.count == 1)
            }
        }
        #expect(sawRedraw)
    }

    @Test func followsDistinctRowsInALongPlanWithRepeatedLabels() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = StudioModel(makePhoto: { try StudioTestPhoto(url: $0) })
        try await model.openPhoto(makePhoto(in: folder))
        model.prompt = "Lighten the photo gradually"
        let steps = (0..<10).map { _ in EditStep.adjust(Adjustment(values: [.exposure: 0.1])) }
        let models = StudioModels(planner: StudioPlanner(steps: steps), segmenter: StudioSegmenter(), generator: StudioGenerator())
        var focusedRows: [UUID] = []
        try await model.runEdit(using: models) { event in
            if case .stepStarted = event, let focus = model.timelineFocus { focusedRows.append(focus) }
        }
        #expect(Set(focusedRows).count == 10)
        #expect(model.steps.filter { $0.step != nil && $0.status == .done }.count == 10)
        #expect(model.timelineFocus == model.steps.last?.id)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makePhoto(in folder: URL) throws -> URL {
        let context = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = try #require(context.makeImage())
        let url = folder.appendingPathComponent("photo.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeScript(photo: URL, area: Bool) throws -> StudioScript {
        let json: [String: Any] = [
            "photo": photo.path, "area": area ? ["x": 0.2, "y": 0.1, "width": 0.4, "height": 0.7] : NSNull(),
            "instruction": "Make the jacket yellow", "backend": "meta", "window": ["width": 1440, "height": 900],
        ]
        return try StudioScript.parse(JSONSerialization.data(withJSONObject: json))
    }
}

private actor StudioPlanner: Planner {
    nonisolated let modelID = "recorded-planner"
    let steps: [EditStep]
    let fails: Bool
    private(set) var requestedArea: NormalizedRect?

    init(steps: [EditStep] = [.select(Selection(id: "jacket", concept: "jacket")),
                             .regenerate(Regeneration(region: "jacket", prompt: "Keep the jacket folds and make it bright yellow"))],
         fails: Bool = false) {
        self.steps = steps
        self.fails = fails
    }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        if fails { throw LumenError.invalidResponse("recorded failure") }
        requestedArea = request.area
        return EditPlan(summary: "Turn the jacket yellow", steps: steps)
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        Critique(satisfied: true, notes: "The jacket is yellow")
    }
}

private struct StudioSegmenter: Segmenter {
    let modelID = "recorded-segmenter"

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        [Segment(label: "jacket", box: .whole, mask: MaskData(size: request.image.size, filledWith: 255))]
    }
}

private struct StudioGenerator: Generator {
    let modelID = "recorded-generator"

    func generate(_ request: GenerateRequest) async throws -> EncodedImage { request.image }
}

private actor StudioTestPhoto: StudioPhoto {
    private let image: EncodedImage
    private(set) var layers: [Layer] = []

    init(url: URL) throws {
        image = EncodedImage(data: try Data(contentsOf: url), format: .png, size: PixelSize(width: 32, height: 24))
    }

    func size() async -> PixelSize { image.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { image }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage { image }
    func apply(_ layer: Layer, assets: AssetStore) async throws { layers.append(layer) }
    func remove(_ layer: Layer.ID) async throws { layers.removeAll { $0.id == layer } }

    func export(to url: URL, format: EncodedImage.Format) async throws {
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let type = format == .jpeg ? UTType.jpeg : .png
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
