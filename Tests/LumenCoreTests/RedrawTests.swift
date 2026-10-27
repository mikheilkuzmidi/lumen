import Foundation
import Testing
@testable import LumenCore

@Suite("Redraw shape", .timeLimit(.minutes(1)))
struct RedrawTests {
    @Test func acceptedObjectExtendsThePatchAndUsesTheBestOverlap() async throws {
        let object = RedrawPhoto.mask(x: 3..<49, y: 6..<46)
        let decoy = RedrawPhoto.mask(x: 0..<2, y: 0..<2)
        let segmenter = RedrawSegmenter(checks: [.success([RedrawPhoto.segment(decoy, score: 0.99),
                                                        RedrawPhoto.segment(object, score: 0.5)])])
        let generator = RedrawGenerator()
        let host = RedrawHost()
        let planner = RedrawPlanner()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        let request = try #require(await generator.requests.first)
        #expect(patch.mask == request.mask.union(object.grown(by: 2)))
        #expect(patch.mask[1, 20] == 255 && request.mask[1, 20] == 0)
        #expect(patch.mask[50, 20] == 255 && request.mask[50, 20] == 0)
        #expect(await generator.requests.count == 1)
        let check = try #require(await segmenter.requests.last)
        #expect(check.image == patch.image && check.concept == "cup")
        #expect(check.box == nil && check.points.isEmpty)
        #expect(events.redrawTraces.contains {
            $0.model == "sam-3.1" && $0.detail == "Check the redraw of cup" && $0.duration >= 0
        })
    }

    @Test(arguments: [false, true]) func poorFirstAttemptKeepsTheBetterRedraw(secondIsBetter: Bool) async throws {
        let smaller = RedrawPhoto.mask(x: 22..<30, y: 22..<30)
        let larger = RedrawPhoto.mask(x: 18..<34, y: 18..<34)
        let masks = secondIsBetter ? [smaller, larger] : [larger, smaller]
        let segmenter = RedrawSegmenter(checks: masks.map { .success([RedrawPhoto.segment($0)]) })
        let generator = RedrawGenerator()
        let host = RedrawHost()
        let planner = RedrawPlanner()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        #expect(await generator.requests.count == 2)
        #expect(patch.image == RedrawPhoto.generated(secondIsBetter ? 2 : 1))
        #expect(patch.mask == (await generator.requests.first)?.mask)
        #expect(events.redrawTraces.contains { $0.detail == "The redraw moved or resized the cup (overlap 0.16)." })
        #expect(await planner.critiques.count == 1)
        #expect(await planner.critiques.first?.done.contains { $0.contains("overlap 0.16") } == true)
    }

    @Test func retryThatKeepsTheShapeExpandsItsMask() async throws {
        let object = RedrawPhoto.mask(x: 3..<49, y: 6..<46)
        let segmenter = RedrawSegmenter(checks: [
            .success([RedrawPhoto.segment(RedrawPhoto.mask(x: 22..<30, y: 22..<30))]),
            .success([RedrawPhoto.segment(object)]),
        ])
        let generator = RedrawGenerator()
        let agent = EditAgent(planner: RedrawPlanner(), segmenter: segmenter, generator: generator, host: RedrawHost())
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        #expect(patch.image == RedrawPhoto.generated(2))
        #expect(patch.mask == (await generator.requests.first)?.mask.union(object.grown(by: 2)))
        #expect(!events.redrawTraces.contains { $0.detail.contains("moved or resized") })
    }

    @Test func exactlyHalfTheOriginalMaskIsAccepted() async throws {
        let object = RedrawPhoto.mask(x: 6..<26, y: 6..<46)
        let segmenter = RedrawSegmenter(checks: [.success([RedrawPhoto.segment(object)])])
        let generator = RedrawGenerator()
        let agent = EditAgent(planner: RedrawPlanner(), segmenter: segmenter, generator: generator, host: RedrawHost())
        _ = try await redrawEvents(agent.run("Make the cup matte black"))
        #expect(await generator.requests.count == 1, "overlap is measured before growing the original mask")
    }

    @Test func shapeCheckComparesMasksAtACommonSize() async throws {
        let object = RedrawPhoto.mask(x: 3..<23, y: 3..<23, size: PixelSize(width: 26, height: 26))
        let segmenter = RedrawSegmenter(checks: [.success([RedrawPhoto.segment(object)])])
        let generatedSize = PixelSize(width: 104, height: 104)
        let generator = RedrawGenerator(size: generatedSize)
        let agent = EditAgent(planner: RedrawPlanner(), segmenter: segmenter, generator: generator, host: RedrawHost())
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        #expect(await generator.requests.count == 1)
        #expect(await segmenter.requests.last?.image.size == generatedSize)
        #expect(patch.mask.size == generatedSize)
        #expect(patch.mask[52, 52] == 255 && patch.mask[0, 0] == 0)
    }

    @Test func aCheckThatFindsSomethingElseDoesNotRetry() async throws {
        // A "white cup" redrawn black is not found as itself; what the check finds lies outside the cup's box.
        let elsewhere = RedrawPhoto.mask(x: 0..<6, y: 0..<6)
        let segmenter = RedrawSegmenter(checks: [.success([RedrawPhoto.segment(elsewhere)])])
        let generator = RedrawGenerator()
        let agent = EditAgent(planner: RedrawPlanner(), segmenter: segmenter, generator: generator, host: RedrawHost())
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        #expect(await generator.requests.count == 1)
        #expect(events.redrawTraces.contains { $0.detail == "Could not check the redraw of cup: what was found is elsewhere." })
        #expect(!events.redrawTraces.contains { $0.detail.contains("moved or resized") })
    }

    @Test func failedRetryKeepsTheFirstRedraw() async throws {
        let object = RedrawPhoto.mask(x: 22..<30, y: 22..<30)
        let segmenter = RedrawSegmenter(checks: [.success([RedrawPhoto.segment(object)])])
        let generator = RedrawGenerator(answers: [.success(RedrawPhoto.generated(1)), .failure(.timedOut)])
        let agent = EditAgent(planner: RedrawPlanner(), segmenter: segmenter, generator: generator, host: RedrawHost())
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        #expect(patch.image == RedrawPhoto.generated(1))
        #expect(patch.mask == (await generator.requests.first)?.mask)
        #expect(events.redrawTraces.contains { $0.detail.hasPrefix("Could not retry the redraw of cup") })
    }

    @Test func cancelledCheckStopsTheEdit() async throws {
        let segmenter = RedrawSegmenter(checks: [.failure(.cancelled)])
        let host = RedrawHost()
        let agent = EditAgent(planner: RedrawPlanner(), segmenter: segmenter, generator: RedrawGenerator(), host: host)
        await #expect(throws: LumenError.cancelled) { try await redrawEvents(agent.run("Make the cup matte black")) }
        #expect(await host.layers.isEmpty)
    }

    @Test(arguments: [false, true]) func failedCheckKeepsTheRedraw(nothingFound: Bool) async throws {
        let answer: Result<[Segment], LumenError> = nothingFound ? .success([]) : .failure(.timedOut)
        let segmenter = RedrawSegmenter(checks: [answer])
        let generator = RedrawGenerator()
        let host = RedrawHost()
        let agent = EditAgent(planner: RedrawPlanner(), segmenter: segmenter, generator: generator, host: host)
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        #expect(patch.image == RedrawPhoto.generated(1))
        #expect(patch.mask == (await generator.requests.first)?.mask)
        #expect(await host.layers.count == 1)
        #expect(await generator.requests.count == 1)
        #expect(events.redrawTraces.contains { $0.detail.contains("Could not check the redraw of cup") })
    }

    @Test func removalSkipsTheShapeCheck() async throws {
        let planner = RedrawPlanner(plan: RedrawPhoto.plan(edit: .remove(Removal(region: "cup"))))
        let segmenter = RedrawSegmenter()
        let host = RedrawHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: RedrawGenerator(), host: host)
        let events = try await redrawEvents(agent.run("Remove the cup"))
        #expect(await segmenter.requests.count == 1)
        #expect(await host.layers.count == 1)
        #expect(!events.redrawTraces.contains { $0.detail.hasPrefix("Check the redraw") })
    }

    @Test func regionWithoutAConceptSkipsTheShapeCheck() async throws {
        var plan = RedrawPhoto.plan()
        plan.steps[0] = .select(Selection(id: "cup", box: NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)))
        let segmenter = RedrawSegmenter()
        let agent = EditAgent(planner: RedrawPlanner(plan: plan), segmenter: segmenter,
                              generator: RedrawGenerator(), host: RedrawHost())
        let events = try await redrawEvents(agent.run("Make this area matte black"))
        #expect(await segmenter.requests.count == 1)
        #expect(events.redrawLayers.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func anotherRedrawReplacesThisRunsLayer(firstIsRemoval: Bool, remove: Bool) async throws {
        let edit = remove ? EditStep.remove(Removal(region: "cup")) : RedrawPhoto.regenerate
        var plan = RedrawPhoto.plan(edit: firstIsRemoval ? .remove(Removal(region: "cup")) : RedrawPhoto.regenerate)
        plan.steps.insert(edit, at: 2)
        let planner = RedrawPlanner(plan: plan)
        let host = RedrawHost()
        let agent = EditAgent(planner: planner, segmenter: RedrawSegmenter(), generator: RedrawGenerator(), host: host)
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        let applied = events.redrawLayers
        #expect(applied.count == 2)
        #expect(await host.layers == [applied[1]])
        #expect(await host.removed == [applied[0].id])
        #expect(await host.cropLayers == [[], []], "each crop renders without the earlier redraw")
        let timeline = events.compactMap { event -> String? in
            switch event {
            case .applied: "applied"
            case .reverted: "reverted"
            default: nil
            }
        }
        #expect(timeline == ["applied", "reverted", "applied"])
        #expect(await planner.critiques.last?.layers.map(\.id) == [applied[1].id.uuidString])
    }

    @Test func failedReplacementKeepsTheEarlierLayerInMemory() async throws {
        var plan = RedrawPhoto.plan()
        plan.steps.insert(RedrawPhoto.regenerate, at: 2)
        let planner = RedrawPlanner(plan: plan)
        let generator = RedrawGenerator()
        let host = RedrawHost(failRemoval: true)
        let agent = EditAgent(planner: planner, segmenter: RedrawSegmenter(), generator: generator, host: host)
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        #expect(await generator.requests.count == 1)
        #expect(await host.layers == events.redrawLayers)
        #expect(await planner.critiques.last?.layers.map(\.id) == events.redrawLayers.map { $0.id.uuidString })
        #expect(events.redrawTraces.contains { $0.kind == .failure && $0.detail.contains("Cannot remove") })
    }

    @Test func followUpKeepsTheEarlierRunsLayer() async throws {
        let planner = RedrawPlanner()
        let host = RedrawHost()
        let agent = EditAgent(planner: planner, segmenter: RedrawSegmenter(), generator: RedrawGenerator(), host: host)
        let first = try await redrawEvents(agent.run("Make the cup matte black"))
        await planner.setPlan(EditPlan(summary: "A different finish", steps: [RedrawPhoto.regenerate]))
        let second = try await redrawEvents(agent.run("Make it satin instead"))
        #expect(await host.layers == first.redrawLayers + second.redrawLayers)
        #expect(await host.removed.isEmpty)
        #expect(await host.cropLayers == [[], first.redrawLayers.map(\.id)])
    }

    @Test(arguments: [false, true]) func revisionWithARedrawGetsAnotherCritique(poorOverlap: Bool) async throws {
        let revision = Critique(satisfied: false, notes: "Needs revision", steps: [
            RedrawPhoto.regenerate, .finish(Finish(reason: "Fixed.")),
        ])
        let planner = RedrawPlanner(critiques: [revision, Critique(satisfied: false, notes: "Still too small")])
        let host = RedrawHost()
        let good = RedrawPhoto.segment(RedrawPhoto.mask(x: 6..<46, y: 6..<46))
        let poor = RedrawPhoto.segment(RedrawPhoto.mask(x: 22..<30, y: 22..<30))
        let segmenter = RedrawSegmenter(checks: [.success([good]), .success([poorOverlap ? poor : good]), .success([poor])])
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: RedrawGenerator(), host: host,
                              configuration: AgentConfiguration(maxRevisions: 1))
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        #expect(await planner.critiques.count == 2)
        #expect(events.redrawReasons == ["Revision limit reached. Still too small"])
        #expect(await host.layers.count == 1)
        #expect(await planner.critiques.last?.after == RedrawPhoto.preview(layers: host.layers))
    }

    @Test func successfulAdjustmentRevisionCanFinish() async throws {
        let revision = Critique(satisfied: false, notes: "Needs contrast", steps: [
            .adjust(Adjustment(values: [.contrast: 10])), .finish(Finish(reason: "Fixed.")),
        ])
        let planner = RedrawPlanner(critiques: [revision])
        let agent = EditAgent(planner: planner, segmenter: RedrawSegmenter(), generator: RedrawGenerator(), host: RedrawHost())
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        #expect(await planner.critiques.count == 1)
        #expect(events.redrawReasons == ["Fixed."])
    }

    @Test func failedAdjustmentRevisionGetsAnotherCritique() async throws {
        let revision = Critique(satisfied: false, notes: "Needs contrast", steps: [
            .adjust(Adjustment(values: [.contrast: 10])), .finish(Finish(reason: "Fixed.")),
        ])
        let planner = RedrawPlanner(critiques: [revision])
        let host = RedrawHost(failAdjustment: true)
        let agent = EditAgent(planner: planner, segmenter: RedrawSegmenter(), generator: RedrawGenerator(), host: host)
        let events = try await redrawEvents(agent.run("Make the cup matte black"))
        #expect(await planner.critiques.count == 2)
        #expect(events.redrawReasons == ["Done."])
    }
}

private func redrawEvents(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func redrawPatch(_ layer: Layer, agent: EditAgent) async throws -> (image: EncodedImage, mask: MaskData) {
    guard case .patch(let image, let mask, _) = layer.content,
          case .image(let photo) = await agent.assets.get(image),
          case .mask(let coverage) = await agent.assets.get(mask) else {
        throw LumenError.invalidResponse("Expected a patch with stored pixels and a mask.")
    }
    return (photo, coverage)
}

private extension Array where Element == AgentEvent {
    var redrawLayers: [Layer] { compactMap { if case .applied(let layer) = $0 { layer } else { nil } } }
    var redrawTraces: [TraceEvent] { compactMap { if case .trace(let trace) = $0 { trace } else { nil } } }
    var redrawReasons: [String] { compactMap { if case .finished(let reason) = $0 { reason } else { nil } } }
}

private actor RedrawPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private var answer: EditPlan
    private var answers: [Critique]
    private(set) var critiques: [CritiqueRequest] = []

    init(plan: EditPlan = RedrawPhoto.plan(), critiques: [Critique] = []) {
        answer = plan
        answers = critiques
    }

    func setPlan(_ plan: EditPlan) { answer = plan }
    func plan(_ request: PlanRequest) async throws -> EditPlan { answer }
    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiques.append(request)
        return answers.isEmpty ? Critique(satisfied: true, notes: "Done.") : answers.removeFirst()
    }
}

private actor RedrawSegmenter: Segmenter {
    let modelID = "sam-3.1"
    private var checks: [Result<[Segment], LumenError>]
    private(set) var requests: [SegmentRequest] = []

    init(checks: [Result<[Segment], LumenError>] = []) { self.checks = checks }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        if requests.count == 1 { return [RedrawPhoto.segment(RedrawPhoto.original)] }
        return try checks.isEmpty ? [RedrawPhoto.segment(RedrawPhoto.mask(x: 6..<46, y: 6..<46))] : checks.removeFirst().get()
    }
}

private actor RedrawGenerator: Generator {
    let modelID = "muse-image-1.0"
    private let size: PixelSize
    private var answers: [Result<EncodedImage, LumenError>]
    private(set) var requests: [GenerateRequest] = []

    init(size: PixelSize = RedrawPhoto.cropSize, answers: [Result<EncodedImage, LumenError>] = []) {
        self.size = size
        self.answers = answers
    }

    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        requests.append(request)
        return try answers.isEmpty ? RedrawPhoto.generated(requests.count, size: size) : answers.removeFirst().get()
    }
}

private actor RedrawHost: EditHost {
    private(set) var layers: [Layer] = []
    private(set) var removed: [Layer.ID] = []
    private(set) var cropLayers: [[Layer.ID]] = []
    private let failAdjustment: Bool
    private let failRemoval: Bool

    init(failAdjustment: Bool = false, failRemoval: Bool = false) {
        self.failAdjustment = failAdjustment
        self.failRemoval = failRemoval
    }
    func size() async -> PixelSize { RedrawPhoto.original.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { RedrawPhoto.preview(layers: layers) }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        cropLayers.append(layers.map(\.id))
        return EncodedImage(data: Data("crop".utf8), format: .png, size: RedrawPhoto.cropSize)
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws {
        if failAdjustment, case .adjustment = layer.content { throw LumenError.invalidResponse("Cannot adjust this photo.") }
        layers.append(layer)
    }
    func remove(_ layer: Layer.ID) async throws {
        if failRemoval { throw LumenError.invalidResponse("Cannot remove this layer.") }
        removed.append(layer)
        layers.removeAll { $0.id == layer }
    }
}

private enum RedrawPhoto {
    static let cropSize = PixelSize(width: 52, height: 52)
    static let original = mask(x: 30..<70, y: 30..<70, size: PixelSize(width: 100, height: 100))
    static let regenerate = EditStep.regenerate(Regeneration(region: "cup", prompt: "A matte black cup, keeping its shape"))

    static func mask(x: Range<Int>, y: Range<Int>, size: PixelSize = cropSize) -> MaskData {
        var coverage = [UInt8](repeating: 0, count: size.width * size.height)
        for row in y { for column in x { coverage[row * size.width + column] = 255 } }
        return MaskData(size: size, coverage: coverage)
    }
    static func segment(_ mask: MaskData, score: Double? = nil) -> Segment {
        Segment(label: "cup", box: mask.boundingBox ?? .whole, mask: mask, score: score)
    }
    static func plan(edit: EditStep = regenerate) -> EditPlan {
        EditPlan(summary: "Change the cup", steps: [.select(Selection(id: "cup", concept: "cup")), edit,
                                                   .finish(Finish(reason: "Ready."))])
    }
    static func generated(_ attempt: Int, size: PixelSize = cropSize) -> EncodedImage {
        EncodedImage(data: Data("attempt \(attempt)".utf8), format: .png, size: size)
    }
    static func preview(layers: [Layer]) -> EncodedImage {
        EncodedImage(data: Data(layers.map { $0.id.uuidString }.joined(separator: ",").utf8), format: .png, size: original.size)
    }
}
