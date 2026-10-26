import Foundation
import Testing
@testable import LumenCore

@Suite("Edit agent", .timeLimit(.minutes(1)))
struct AgentTests {
    @Test func selectsAdjustsAndRedrawsAsSeparateLayers() async throws {
        let plan = EditPlan(summary: "Change the coat", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4, .saturation: 10])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy wool coat")),
            .finish(Finish(reason: "The coat is ready.")),
        ])
        let planner = AgentPlanner(plan: plan)
        let segmenter = AgentSegmenter(segments: [segment()])
        let generator = AgentGenerator()
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host,
                              configuration: AgentConfiguration(previewLongEdge: 900))
        let events = try await collect(agent.run("Make the coat navy"))
        let layers = await host.layers
        #expect(layers == events.layers)
        #expect(layers.map(\.label) == ["Coat: exposure −0.4, saturation +10", "Coat: redrawn as a navy wool coat"])
        let adjustment = try #require(layers.first)
        guard case .adjustment(let values, let maskID) = adjustment.content else {
            Issue.record("Expected an adjustment layer")
            return
        }
        #expect(values == [.exposure: -0.4, .saturation: 10])
        let selectedMask = try #require(maskID)
        #expect(await agent.assets.get(selectedMask) == .mask(segment().mask))
        let patch = try #require(layers.last)
        guard case .patch(let imageID, let patchMaskID, let rect) = patch.content else {
            Issue.record("Expected a patch layer")
            return
        }
        #expect(abs(rect.x - 0.14) < 0.000001)
        #expect(abs(rect.y - 0.225) < 0.000001)
        #expect(abs(rect.width - 0.52) < 0.000001)
        #expect(abs(rect.height - 0.65) < 0.000001)
        #expect(await agent.assets.get(imageID) == .image(AgentGenerator.image))
        let generateRequest = try #require(await generator.requests.first)
        #expect(generateRequest.prompt == "a navy wool coat")
        #expect(generateRequest.mask == segment().mask.cropped(to: rect).resized(to: generateRequest.image.size))
        #expect(await agent.assets.get(patchMaskID) == .mask(generateRequest.mask.resized(to: AgentGenerator.image.size)))
        #expect(await host.crops.map(\.maxLongEdge) == [2048])
        #expect(await host.crops.map(\.rect) == [rect])
        #expect(await host.previews == [900, 900])
        let request = try #require(await planner.plans.first)
        #expect(request.instruction == "Make the coat navy")
        #expect(request.regions.isEmpty && request.done.isEmpty)
        #expect(events.stepIndices == [0, 1, 2, 3])
        #expect(events.reasons == ["The coat is ready."])
        #expect(await planner.critiques.isEmpty)
        let calls = events.traces.filter { $0.model != nil }
        #expect(calls.map(\.kind) == [.plan, .select, .regenerate])
        #expect(calls.map(\.model) == ["muse-spark-1.3", "sam-3.1", "muse-image-1.0"])
        #expect(calls.allSatisfy { !$0.detail.isEmpty && $0.duration >= 0 && $0.started <= Date() })
    }

    @Test func areaFillsInOnlyAMissingSelectionBox() async throws {
        let area = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        let box = NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
        let point = NormalizedPoint(x: 0.4, y: 0.4)
        let planner = AgentPlanner(plan: EditPlan(summary: "Select", steps: [
            .select(Selection(id: "coat", concept: "coat", points: [point])),
            .select(Selection(id: "sleeve", box: box, points: [point])),
            .finish(Finish(reason: "Selected")),
        ]))
        let segmenter = AgentSegmenter(segments: [segment()])
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: AgentGenerator(), host: AgentHost())
        _ = try await collect(agent.run("Select the coat", area: area))
        #expect(await planner.plans.first?.area == area)
        let requests = await segmenter.requests
        #expect(requests.map(\.box) == [area, box])
        #expect(requests.map(\.concept) == ["coat", nil])
        #expect(requests.map(\.points) == [[point], [point]])
    }

    @Test func unionsSegmentsBeforeInvertingTheSelection() async throws {
        let size = PixelSize(width: 2, height: 2)
        let first = Segment(label: "coat", box: .whole, mask: MaskData(size: size, coverage: [255, 0, 0, 0]))
        let second = Segment(label: "coat", box: .whole, mask: MaskData(size: size, coverage: [0, 128, 0, 0]))
        let planner = AgentPlanner(plan: EditPlan(summary: "Select outside", steps: [
            .select(Selection(id: "outside", concept: "coat", invert: true)),
            .adjust(Adjustment(region: "outside", values: [.contrast: 5])),
        ]))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [first, second]),
                              generator: AgentGenerator(), host: host)
        let events = try await collect(agent.run("Change the background"))
        let selected = try #require(events.selections.first)
        #expect(selected.mask.coverage == [0, 127, 255, 255])
        #expect(selected.box == .whole)
        let request = try #require(await planner.critiques.first)
        #expect(request.regions.first?.area == selected.mask.area)
        #expect(request.regions.first?.box == selected.box)
        #expect(request.done == ["Outside: selected", "Outside: contrast +5"])
    }

    @Test(arguments: [false, true]) func nothingFoundSkipsDependentSteps(invert: Bool) async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Edit the missing coat", steps: [
            .select(Selection(id: "coat", concept: "coat", invert: invert)),
            .adjust(Adjustment(region: "coat", values: [.contrast: 20])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy coat")),
            .remove(Removal(region: "coat")),
            .adjust(Adjustment(values: [.exposure: 0.2])),
        ]))
        let generator = AgentGenerator()
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: generator, host: host)
        let events = try await collect(agent.run("Make the coat navy"))
        #expect(events.selections.isEmpty)
        #expect(await generator.requests.isEmpty)
        #expect(await host.layers.map(\.label) == ["Photo: exposure +0.2"])
        #expect(events.traces.contains { $0.detail == "Nothing found for coat." })
        #expect(events.traces.filter { $0.detail.hasPrefix("Skipped") }.count == 3)
        #expect(await planner.critiques.first?.regions.isEmpty == true)
        #expect(await planner.critiques.first?.done == ["Photo: exposure +0.2"])
    }

    @Test func critiqueRevisesUsingTheSelectedRegionAndCompletedSteps() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Darken the coat", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4])),
        ]), critiques: [
            .success(Critique(satisfied: false, notes: "Needs more saturation", steps: [
                .adjust(Adjustment(region: "coat", values: [.saturation: 10])),
            ])),
            .success(Critique(satisfied: true, notes: "The coat looks right.")),
        ])
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                              generator: AgentGenerator(), host: host)
        let events = try await collect(agent.run("Darken the coat"))
        #expect(events.layers.map(\.label) == ["Coat: exposure −0.4", "Coat: saturation +10"])
        #expect(events.stepIndices == [0, 1, 2])
        #expect(events.critiques.map(\.satisfied) == [false, true])
        #expect(events.reasons == ["The coat looks right."])
        let requests = await planner.critiques
        #expect(requests.count == 2)
        #expect(requests[0].instruction == "Darken the coat")
        #expect(requests[0].before == AgentPhoto.preview(layers: 0))
        #expect(requests[0].after == AgentPhoto.preview(layers: 1))
        #expect(requests[1].before == requests[0].before)
        #expect(requests[1].after == AgentPhoto.preview(layers: 2))
        #expect(requests[1].regions == [RegionInfo(id: "coat", concept: "coat", box: segment().mask.boundingBox!, area: segment().mask.area)])
        #expect(requests[1].done == ["Coat: selected", "Coat: exposure −0.4", "Coat: saturation +10"])
    }

    @Test func stepLimitIncludesStepsFromRevisions() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [
            .adjust(Adjustment(values: [.exposure: 0.2])),
        ]), critiques: [.success(Critique(satisfied: false, notes: "More contrast", steps: [
            .adjust(Adjustment(values: [.contrast: 10])),
            .crop(Crop(rect: .whole)),
            .finish(Finish(reason: "Done")),
        ]))])
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host,
                              configuration: AgentConfiguration(maxSteps: 2))
        let events = try await collect(agent.run("Improve the photo"))
        #expect(events.stepIndices == [0, 1])
        #expect(await host.layers.count == 2)
        #expect(await planner.critiques.count == 1)
        #expect(events.reasons == ["Step limit reached."])
    }

    @Test func zeroStepsMakesNoModelCalls() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Unused", steps: []))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host,
                              configuration: AgentConfiguration(maxSteps: 0))
        let events = try await collect(agent.run("Improve the photo"))
        #expect(await planner.plans.isEmpty)
        #expect(await host.previews.isEmpty)
        #expect(events.reasons == ["Step limit reached."])
    }

    @Test func revisionLimitStopsEvenWhenTheCriticKeepsAsking() async throws {
        let revision = Critique(satisfied: false, notes: "Try more contrast", steps: [.adjust(Adjustment(values: [.contrast: 10]))])
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]),
                                   critiques: [.success(revision), .success(revision)])
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host,
                              configuration: AgentConfiguration(maxRevisions: 1))
        let events = try await collect(agent.run("Improve the photo"))
        #expect(await host.layers.count == 2)
        #expect(await planner.critiques.count == 2)
        #expect(events.reasons == ["Revision limit reached. Try more contrast"])
    }

    @Test func refusedStepContinuesWithTheNextLayer() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Redraw and adjust", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .regenerate(Regeneration(region: "coat", prompt: "a navy coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4])),
            .finish(Finish(reason: "Adjusted the coat.")),
        ]))
        let generator = AgentGenerator(error: .refused("This edit was declined."))
        let host = AgentHost()
        let events = try await collect(EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                                                 generator: generator, host: host).run("Change the coat"))
        #expect(await host.layers.map(\.label) == ["Coat: exposure −0.4"])
        #expect(events.traces.contains { $0.kind == .failure && $0.detail.contains("declined") })
        #expect(events.traces.filter { $0.model == "muse-image-1.0" }.count == 1)
        #expect(events.reasons == ["Adjusted the coat."])
    }

    @Test func refusedPlanFailsTheStream() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Unused", steps: []), error: .refused("Cannot plan this edit."))
        let host = AgentHost()
        var events: [AgentEvent] = []
        do {
            for try await event in EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []),
                                             generator: AgentGenerator(), host: host).run("Change the photo") {
                events.append(event)
            }
            Issue.record("A refused plan must fail")
        } catch {
            #expect(error as? LumenError == .refused("Cannot plan this edit."))
        }
        #expect(await host.layers.isEmpty)
        #expect(events.stepIndices.isEmpty)
        #expect(events.traces.contains { $0.kind == .failure })
    }

    @Test func removalUsesItsPromptAndClipsContextToThePhoto() async throws {
        let mask = MaskData(size: PixelSize(width: 2, height: 2), coverage: [255, 0, 0, 0])
        let planner = AgentPlanner(plan: EditPlan(summary: "Remove", steps: [
            .select(Selection(id: "object", concept: "object")),
            .remove(Removal(region: "object")),
            .crop(Crop(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))),
        ]))
        let generator = AgentGenerator()
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [Segment(label: "object", box: .whole, mask: mask)]),
                              generator: generator, host: host)
        let events = try await collect(agent.run("Remove the object and crop"))
        #expect(await generator.requests.first?.prompt == "Remove the selected object and fill the area naturally from its surroundings")
        let rect = try #require(await host.crops.first?.rect)
        #expect(rect.x == 0 && rect.y == 0)
        #expect(abs(rect.width - 0.575) < 0.000001 && abs(rect.height - 0.575) < 0.000001)
        #expect(events.layers.map(\.label) == ["Object: removed", "Photo: cropped"])
        #expect(events.layers.last?.content == .crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(events.traces.contains { $0.kind == .remove && $0.model == "muse-image-1.0" })
    }

    @Test func cancelledPlannerResultAddsNoLayers() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]), gate: gate)
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host)
        let consumer = Task { try await collect(agent.run("Brighten")) }
        await gate.waitUntilEntered()
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.isEmpty)
        #expect(await host.previews.count == 1)
        #expect(await gate.wasCancelled)
    }

    @Test func cancelledGenerationDiscardsItsResultAndPreservesCompletedLayers() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Change coat", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy coat")),
            .crop(Crop(rect: .whole)),
        ]))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                              generator: AgentGenerator(gate: gate), host: host)
        let consumer = Task { try await collect(agent.run("Change the coat")) }
        await gate.waitUntilEntered()
        #expect(await host.layers.count == 1)
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.map(\.label) == ["Coat: exposure −0.4"])
        #expect(await gate.wasCancelled)
    }

    @Test func terminatingTheStreamCancelsTheModelTask() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]), gate: gate)
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host)
        let consumer = Task { try await collect(agent.run("Brighten")) }
        await gate.waitUntilEntered()
        consumer.cancel()
        _ = try? await consumer.value
        await gate.release()
        await gate.waitUntilLeft()
        #expect(await gate.wasCancelled)
        #expect(await host.layers.isEmpty)
    }

    @Test func cancellationDuringApplicationRollsBackTheLayer() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]))
        let host = AgentHost(applyGate: gate)
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host)
        let consumer = Task { try await collect(agent.run("Brighten")) }
        await gate.waitUntilEntered()
        #expect(await host.layers.count == 1)
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.isEmpty)
        #expect(await host.removed.count == 1)
    }

    @Test func cancellationErrorEndsTheStreamWithTheDomainError() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Unused", steps: []), throwsCancellation: true)
        let host = AgentHost()
        do {
            _ = try await collect(EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []),
                                            generator: AgentGenerator(), host: host).run("Brighten"))
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.isEmpty)
    }

    private func segment() -> Segment {
        var coverage = [UInt8](repeating: 0, count: 100)
        for y in 3..<8 {
            for x in 2..<6 { coverage[y * 10 + x] = 255 }
        }
        return Segment(label: "coat", box: .whole, mask: MaskData(size: PixelSize(width: 10, height: 10), coverage: coverage))
    }
}

private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private extension Array where Element == AgentEvent {
    var layers: [Layer] { compactMap { if case .applied(let layer) = $0 { layer } else { nil } } }
    var stepIndices: [Int] { compactMap { if case .stepStarted(let index, _) = $0 { index } else { nil } } }
    var selections: [Segment] { compactMap { if case .selected(_, let segment) = $0 { segment } else { nil } } }
    var critiques: [Critique] { compactMap { if case .critiqued(let critique) = $0 { critique } else { nil } } }
    var reasons: [String] { compactMap { if case .finished(let reason) = $0 { reason } else { nil } } }
    var traces: [TraceEvent] { compactMap { if case .trace(let trace) = $0 { trace } else { nil } } }
}

private actor AgentPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private let answer: EditPlan
    private var answers: [Result<Critique, LumenError>]
    private let error: LumenError?
    private let gate: AgentGate?
    private let throwsCancellation: Bool
    private(set) var plans: [PlanRequest] = []
    private(set) var critiques: [CritiqueRequest] = []

    init(plan: EditPlan, critiques: [Result<Critique, LumenError>] = [], error: LumenError? = nil,
         gate: AgentGate? = nil, throwsCancellation: Bool = false) {
        answer = plan
        answers = critiques
        self.error = error
        self.gate = gate
        self.throwsCancellation = throwsCancellation
    }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        plans.append(request)
        await gate?.wait()
        await gate?.recordReturn(cancelled: Task.isCancelled)
        if throwsCancellation { throw CancellationError() }
        if let error { throw error }
        return answer
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiques.append(request)
        return try answers.isEmpty ? Critique(satisfied: true, notes: "Done.") : answers.removeFirst().get()
    }
}

private actor AgentSegmenter: Segmenter {
    let modelID = "sam-3.1"
    private let segments: [Segment]
    private(set) var requests: [SegmentRequest] = []

    init(segments: [Segment]) { self.segments = segments }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        return segments
    }
}

private actor AgentGenerator: Generator {
    let modelID = "muse-image-1.0"
    static let image = AgentPhoto.generated
    private let error: LumenError?
    private let gate: AgentGate?
    private(set) var requests: [GenerateRequest] = []

    init(error: LumenError? = nil, gate: AgentGate? = nil) {
        self.error = error
        self.gate = gate
    }

    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        requests.append(request)
        await gate?.wait()
        await gate?.recordReturn(cancelled: Task.isCancelled)
        if let error { throw error }
        return Self.image
    }
}

private actor AgentHost: EditHost {
    struct RenderedCrop: Sendable {
        var rect: NormalizedRect
        var maxLongEdge: Int
    }

    private(set) var layers: [Layer] = []
    private(set) var previews: [Int] = []
    private(set) var crops: [RenderedCrop] = []
    private(set) var removed: [Layer.ID] = []
    private let applyGate: AgentGate?

    init(applyGate: AgentGate? = nil) { self.applyGate = applyGate }

    func size() async -> PixelSize { PixelSize(width: 10, height: 10) }

    func render(maxLongEdge: Int) async throws -> EncodedImage {
        previews.append(maxLongEdge)
        return AgentPhoto.preview(layers: layers.count)
    }

    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        crops.append(RenderedCrop(rect: region, maxLongEdge: maxLongEdge))
        return AgentPhoto.crop
    }

    func apply(_ layer: Layer, assets: AssetStore) async throws {
        layers.append(layer)
        await applyGate?.wait()
        await applyGate?.recordReturn(cancelled: Task.isCancelled)
    }

    func remove(_ layer: Layer.ID) async throws {
        removed.append(layer)
        layers.removeAll { $0.id == layer }
    }
}

private enum AgentPhoto {
    static func preview(layers: Int) -> EncodedImage {
        let images = [
            "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFElEQVR4nGMQERH5TwxmGFVIX4UABkJ7DV6H+GcAAAAASUVORK5CYII=",
            "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFElEQVR4nGPQ0ND4TwxmGFVIX4UA17iSfTwsfN8AAAAASUVORK5CYII=",
            "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFElEQVR4nGOwsbH5TwxmGFVIX4UAqT2p7R6JOgIAAAAASUVORK5CYII=",
        ]
        return EncodedImage(data: Data(base64Encoded: images[min(layers, 2)])!, format: .png, size: PixelSize(width: 10, height: 10))
    }

    static let crop = EncodedImage(
        data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAAEklEQVR4nGMICAj4jw8zDAUFALYLXNFb7LvbAAAAAElFTkSuQmCC")!,
        format: .png, size: PixelSize(width: 8, height: 6))
    static let generated = EncodedImage(
        data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAYAAABr5z2BAAAAF0lEQVR4nGNISUn5TwlmGDVg1IDhYQAAm0OgUBCLqvQAAAAASUVORK5CYII=")!,
        format: .png, size: PixelSize(width: 16, height: 12))
}

/// Lets a fake model finish after its caller has been cancelled.
private actor AgentGate {
    private var entered = false
    private var released = false
    private var left = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var completionObservers: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func wait() async {
        entered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        if !released { await withCheckedContinuation { waiting = $0 } }
    }

    func recordReturn(cancelled: Bool) {
        wasCancelled = cancelled
        left = true
        for observer in completionObservers { observer.resume() }
        completionObservers.removeAll()
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }

    func waitUntilLeft() async {
        if !left { await withCheckedContinuation { completionObservers.append($0) } }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}
