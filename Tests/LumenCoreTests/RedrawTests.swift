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
        // A recolour shows through SAM's own mask and the redrawn object, not the generator's grown mask.
        #expect(patch.mask == RedrawPhoto.inCrop.union(object))
        #expect(patch.mask[4, 20] == 255 && RedrawPhoto.inCrop[4, 20] == 0)
        #expect(patch.mask[47, 20] == 255 && RedrawPhoto.inCrop[47, 20] == 0)
        #expect(patch.mask[2, 20] == 0 && request.mask[5, 20] == 255, "the generator's grown edge doesn't show")
        #expect(request.prompt == "A matte black cup, keeping its shape. Change only the cup in the centre of this picture, and nothing else.")
        #expect(await generator.requests.count == 1)
        let check = try #require(await segmenter.requests.last)
        #expect(check.image == patch.image && check.concept == "cup")
        #expect(check.box == nil && check.points.isEmpty)
        #expect(events.redrawTraces.contains {
            $0.model == "sam-3.1" && $0.detail == "Check the redraw of cup" && $0.duration >= 0
        })
    }

    /// A new sunset stopped at a bridge's main cable, which SAM's sky had left out with the bridge: a sky's redraw shows
    /// through the pockets of new sky the host finds too; a cup's doesn't ask for any.
    @Test(arguments: ["sky", "cup"]) func aSkysRedrawTakesInThePocketsOfNewSky(concept: String) async throws {
        let pocket = RedrawPhoto.mask(x: 0..<3, y: 0..<3)
        let host = RedrawHost(pockets: pocket)
        let planner = RedrawPlanner(plan: EditPlan(summary: "New sky", steps: [
            .select(Selection(id: "region", concept: concept)),
            .regenerate(Regeneration(region: "region", prompt: "A dramatic sunset")),
            .finish(Finish(reason: "Ready.")),
        ]))
        let agent = EditAgent(planner: planner, segmenter: RedrawSegmenter(), generator: RedrawGenerator(), host: host)
        let events = try await redrawEvents(agent.run("Replace the \(concept) with a sunset"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        #expect(await host.pocketCalls == (concept == "sky" ? 1 : 0))
        #expect((patch.mask[1, 1] == 255) == (concept == "sky"))
        #expect(EditAgent.isSky("the sky") && EditAgent.isSky("Sky") && !EditAgent.isSky("skyline") && !EditAgent.isSky(nil))
    }

    /// "shirts" found nothing in a photo of three women's tops, where "shirt" finds each: a plural that finds nothing is
    /// looked for once more in the singular.
    @Test func aPluralThatFindsNothingIsLookedForInTheSingular() async throws {
        #expect(EditAgent.singular("shirts") == "shirt")
        #expect(EditAgent.singular("red t-shirts") == "red t-shirt")
        #expect(EditAgent.singular("hoodies") == "hoodie" || EditAgent.singular("hoodies") == "hoody")
        #expect(EditAgent.singular("dresses") == nil || EditAgent.singular("dresses") == "dresse")
        #expect(EditAgent.singular("benches") == "bench")
        #expect(EditAgent.singular("bus") == nil && EditAgent.singular("glass") == nil && EditAgent.singular("sunglasses") == nil)
        #expect(EditAgent.singular("cactus") == nil && EditAgent.singular("sky") == nil)
        let segmenter = PluralSegmenter()
        let planner = RedrawPlanner(plan: EditPlan(summary: "Blue tops", steps: [
            .select(Selection(id: "tops", concept: "shirts")),
            .regenerate(Regeneration(region: "tops", prompt: "Royal blue shirts")),
            .finish(Finish(reason: "Ready.")),
        ]))
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: RedrawGenerator(), host: RedrawHost())
        let events = try await redrawEvents(agent.run("Make the shirts blue"))
        #expect(await segmenter.concepts.prefix(2) == ["shirts", "shirt"])
        #expect(!events.redrawLayers.isEmpty, "the shirts were found in the singular and redrawn")
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
        #expect(patch.mask == RedrawPhoto.inCrop)
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
        #expect(patch.mask == RedrawPhoto.inCrop.union(object))
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
        #expect(patch.mask == RedrawPhoto.inCrop)
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
        #expect(patch.mask == RedrawPhoto.inCrop)
        #expect(await host.layers.count == 1)
        #expect(await generator.requests.count == 1)
        #expect(events.redrawTraces.contains { $0.detail.contains("Could not check the redraw of cup") })
    }

    @Test func aRemovalIsLookedForAgainWhereItWas() async throws {
        let planner = RedrawPlanner(plan: RedrawPhoto.plan(edit: .remove(Removal(region: "cup"))))
        let segmenter = RedrawSegmenter(checks: [.success([])])
        let host = RedrawHost()
        let generator = RedrawGenerator()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        let events = try await redrawEvents(agent.run("Remove the cup"))
        // A removal keeps its grown mask, to take all of the thing out.
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        let request = try #require(await generator.requests.first)
        // The patch shows through that mask softened outside the cup, by 1.5% of the crop.
        #expect(patch.mask == request.mask.blurred(by: Double(RedrawPhoto.cropSize.width) * 0.015))
        #expect(request.prompt == "Remove the whole cup in the centre of this picture, every part of it. Fill its place "
            + "with what is behind it, continuing the surroundings naturally. Change nothing else.")
        #expect(await generator.requests.count == 1)
        let check = try #require(await segmenter.requests.last)
        #expect(await segmenter.requests.count == 2)
        #expect(check.concept == "cup" && check.image == patch.image)
        #expect(events.redrawTraces.contains { $0.model == "sam-3.1" && $0.detail == "Check the removal of cup" })
        #expect(!events.redrawTraces.contains { $0.detail.contains("still found") || $0.detail.contains("Could not check") })
        // Its context is three times the cup's size, clipped to the photo: the cup lies 0.3...0.7 of a 100 px photo.
        guard case .patch(_, _, let rect) = try #require(events.redrawLayers.last).content else {
            Issue.record("Expected a patch")
            return
        }
        #expect(rect == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        // Its mask reaches 6% of the crop's short side past the cup, beyond the soft edge the patch blends in with.
        let cup = RedrawPhoto.original.cropped(to: rect).resized(to: RedrawPhoto.cropSize)
        #expect(request.mask == cup.grown(by: 3))
    }

    @Test(arguments: [false, true]) func aRemovalThatLeftTheThingIsTriedOnceMore(secondRemoves: Bool) async throws {
        let left = RedrawPhoto.segment(RedrawPhoto.mask(x: 16..<36, y: 16..<36))
        let segmenter = RedrawSegmenter(checks: [.success([left]), .success(secondRemoves ? [] : [left])])
        let generator = RedrawGenerator()
        let planner = RedrawPlanner(plan: RedrawPhoto.plan(edit: .remove(Removal(region: "cup"))))
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: RedrawHost())
        let events = try await redrawEvents(agent.run("Remove the cup"))
        let patch = try await redrawPatch(#require(events.redrawLayers.last), agent: agent)
        #expect(await generator.requests.count == 2)
        #expect(patch.image == RedrawPhoto.generated(secondRemoves ? 2 : 1), "an attempt that left as much is not kept")
        let still = "The cup is still found where it was after its removal"
        #expect(events.redrawTraces.contains { $0.kind == .remove && $0.detail.hasPrefix(still) } == !secondRemoves)
        #expect(await planner.critiques.first?.done.contains { $0.hasPrefix(still) } == !secondRemoves)
    }

    @Test func aRemovalWithoutAConceptIsNotLookedFor() async throws {
        var plan = RedrawPhoto.plan(edit: .remove(Removal(region: "cup")))
        plan.steps[0] = .select(Selection(id: "cup", box: NormalizedRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)))
        let segmenter = RedrawSegmenter()
        let generator = RedrawGenerator()
        let agent = EditAgent(planner: RedrawPlanner(plan: plan), segmenter: segmenter, generator: generator, host: RedrawHost())
        _ = try await redrawEvents(agent.run("Remove this"))
        #expect(await segmenter.requests.count == 1)
        #expect(await generator.requests.count == 1)
        #expect(await generator.requests.first?.prompt.hasPrefix("Remove the whole cup in the centre") == true)
    }

    @Test func thePromptSaysWhichThingToChangeAndWhere() {
        let crop = NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        #expect(EditAgent.place(of: NormalizedRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1), in: crop) == "in the centre")
        #expect(EditAgent.place(of: NormalizedRect(x: 0.2, y: 0.45, width: 0.1, height: 0.1), in: crop) == "on the left")
        #expect(EditAgent.place(of: NormalizedRect(x: 0.7, y: 0.2, width: 0.1, height: 0.1), in: crop) == "at the top right")
        #expect(EditAgent.place(of: NormalizedRect(x: 0.45, y: 0.7, width: 0.1, height: 0.1), in: crop) == "at the bottom")
        #expect(EditAgent.redrawPrompt("Recolour the grey T-shirt to navy", thing: "t-shirt", place: "on the left")
            == "Recolour the grey T-shirt to navy. Change only the t-shirt on the left of this picture, and nothing else.")
        #expect(EditAgent.redrawPrompt("A navy coat!  ", thing: "coat", place: "in the centre")
            == "A navy coat! Change only the coat in the centre of this picture, and nothing else.")
        // Seven flowers are seven, not the one in the centre.
        #expect(EditAgent.redrawPrompt("Recolour the orange flowers to deep purple", thing: "flower", place: "in the centre", count: 7)
            == "Recolour the orange flowers to deep purple. This is for all 7 of these flowers in the picture: change every one of them fully, and nothing else.")
        #expect(EditAgent.redrawPrompt(nil, thing: "sign", place: "in the centre", count: 2).hasPrefix("Remove all 2 signs in this picture"))
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
        #expect(await host.closeUpLayers == [[], [applied[1].id]], "one close-up before this run's first redraw, one for the check")
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

/// SAM, which knows a shirt but not "shirts".
private actor PluralSegmenter: Segmenter {
    let modelID = "sam-3.1"
    private(set) var concepts: [String?] = []
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        concepts.append(request.concept)
        return request.concept == "shirts" ? [] : [RedrawPhoto.segment(RedrawPhoto.original)]
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
    private(set) var closeUpLayers: [[Layer.ID]] = []
    private let failAdjustment: Bool
    private let failRemoval: Bool
    private let foundPockets: MaskData?
    private(set) var pocketCalls = 0

    init(failAdjustment: Bool = false, failRemoval: Bool = false, pockets: MaskData? = nil) {
        self.failAdjustment = failAdjustment
        self.failRemoval = failRemoval
        foundPockets = pockets
    }
    func pockets(_ generated: EncodedImage, over original: EncodedImage, outside mask: MaskData, reach: Int) async throws -> Pockets? {
        pocketCalls += 1
        return foundPockets.map { Pockets(mask: $0, image: generated) }
    }
    func size() async -> PixelSize { RedrawPhoto.original.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { RedrawPhoto.preview(layers: layers) }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        // The generator's crops; the critic's close-ups are smaller.
        if maxLongEdge == 2048 { cropLayers.append(layers.map(\.id)) } else { closeUpLayers.append(layers.map(\.id)) }
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
    /// The original as it falls in the redraw's crop.
    static let inCrop = mask(x: 6..<46, y: 6..<46)
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
