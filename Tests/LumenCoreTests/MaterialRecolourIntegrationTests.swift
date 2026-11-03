import Foundation
import Testing
@testable import LumenCore

@Suite("Material recolour dispatch", .timeLimit(.minutes(1)))
struct MaterialRecolourIntegrationTests {
    static let wording = "Recolour all four T-shirts to a solid fully dyed rich saturated vivid deep navy blue instead of black, maroon, light grey and white, keeping their knit fabric texture, weave, folds, wrinkles, shadows, edges and the scene’s lighting and exact shape"
    static let instruction = "Make the shirts in the selected photos blue. Preserve their fabric texture, logos, folds and lighting."

    @Test func actualFourShirtWordingUsesApprovedInstancesAndPreparedContract() async throws {
        let host = MaterialTestHost(.accepted), generator = MaterialTestGenerator()
        let agent = MaterialFixture.agent(host: host, generator: generator)
        _ = try await materialEvents(agent.run(Self.instruction))
        let input = try #require(await host.inputs.first)
        #expect(input.instances.count == 4)
        #expect(input.instances.allSatisfy { $0.size == input.original.size })
        let approved = MaterialFixture.union.cropped(to: input.region).resized(to: input.original.size)
        #expect(input.instances.allSatisfy { zip($0.coverage, approved.coverage).allSatisfy { $0 <= $1 } })
        #expect(input.instances.dropFirst().reduce(input.instances[0]) { $0.union($1) } == approved)
        #expect(input.instances[0][2, 10] == 96, "Clipping must preserve soft coverage, not square it")
        #expect(await host.legacyCalls == 0)
        let layer = try #require(await host.layers.last)
        #expect(layer.precompositedEdges == true)
        #expect(layer.sourceReferenced == true)
        guard case .patch(let imageID, _, let rect) = layer.content,
              case .image(let image) = await agent.assets.get(imageID) else { Issue.record("No prepared patch"); return }
        #expect(image.data == Data("material prepared".utf8))
        #expect(rect == input.region)
        #expect(input.generated == MaterialFixture.generated)
        #expect(await generator.requests.count == 1)
    }

    @Test func decliningAndDefaultNilHostsKeepLegacyPathAndGeneratorInput() async throws {
        let accepted = MaterialTestHost(.accepted), declined = MaterialTestHost(.declined), legacy = MaterialTestHost(.accepted)
        let a = MaterialTestGenerator(), b = MaterialTestGenerator(), c = MaterialTestGenerator()
        _ = try await materialEvents(MaterialFixture.agent(host: accepted, generator: a).run(Self.instruction))
        _ = try await materialEvents(MaterialFixture.agent(host: declined, generator: b).run(Self.instruction))
        _ = try await materialEvents(MaterialFixture.agent(host: MaterialLegacyHost(base: legacy), generator: c).run(Self.instruction))
        #expect(await declined.inputs.count == 1)
        #expect(await declined.legacyCalls == 1)
        #expect(await legacy.inputs.isEmpty, "The protocol default is nil, without adapter changes")
        #expect(await legacy.legacyCalls == 1)
        #expect(await accepted.layers.last?.sourceReferenced == true)
        #expect(await declined.layers.last?.sourceReferenced == nil)
        #expect(await legacy.layers.last?.sourceReferenced == nil)
        let first = await a.requests, second = await b.requests, third = await c.requests
        #expect(first.count == second.count && first.count == third.count)
        #expect(zip(first, second).allSatisfy { $0.image == $1.image && $0.mask == $1.mask && $0.prompt == $1.prompt })
        #expect(zip(first, third).allSatisfy { $0.image == $1.image && $0.mask == $1.mask && $0.prompt == $1.prompt },
                "No extra calls, prompt or mask changes reach the generator")
    }

    @Test func touchingInstancesKeepApprovedScopeAcrossNoncommutingResampling() async throws {
        let cropSize = PixelSize(width: 63, height: 47)
        let instances: [MaskData] = [0, 16, 32, 48].map { left in
            var mask = MaskData(size: MaterialFixture.size, filledWith: 0)
            for y in 0..<mask.size.height { for x in left..<(left + 16) { mask.coverage[y * mask.size.width + x] = 255 } }
            return mask
        }
        let fullUnion = instances.dropFirst().reduce(instances[0]) { $0.union($1) }
        let resized = instances.map { $0.resized(to: cropSize) }
        let resizedUnion = resized.dropFirst().reduce(resized[0]) { $0.union($1) }
        #expect(resizedUnion.coverage != fullUnion.resized(to: cropSize).coverage,
                "This fixture must exercise max-union and bilinear-resize noncommutation")
        let host = MaterialTestHost(.accepted, cropSize: cropSize)
        _ = try await materialEvents(MaterialFixture.agent(host: host, instances: instances).run(Self.instruction))
        let input = try #require(await host.inputs.first)
        #expect(input.instances.count == 4)
        let approved = fullUnion.cropped(to: input.region).resized(to: input.original.size)
        #expect(input.instances == resized)
        #expect(input.instances.allSatisfy { zip($0.coverage, approved.coverage).allSatisfy { $0 <= $1 } })
        #expect(input.instances.dropFirst().reduce(input.instances[0]) { $0.union($1) } == resizedUnion,
                "Contact coverage must remain as sampled, without inventing ownership")
        #expect(await host.legacyCalls == 0)
        #expect(await host.layers.last?.precompositedEdges == true)
    }

    @Test(arguments: ["area", "box", "points", "invert", "gradient", "shadow", "colours", "single", "not-every", "crop", "ordinary", "user-pattern", "different-colours"])
    func constrainedSingleOrUncertainScopesDoNotUseMaterialPath(_ mode: String) async throws {
        let host = MaterialTestHost(.accepted), generator = MaterialTestGenerator()
        var selection = Selection(id: "shirts", concept: "t-shirt", every: true)
        var area: NormalizedRect?, prefix: [EditStep] = []
        var prompt = Self.wording, instruction = Self.instruction
        var instances = MaterialFixture.instances
        switch mode {
        case "area": area = NormalizedRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
        case "box": selection.box = .whole
        case "points": selection.points = [NormalizedPoint(x: 0.2, y: 0.5)]
        case "invert": selection.invert = true
        case "gradient": selection.gradient = Gradient(from: NormalizedPoint(x: 0, y: 0), to: NormalizedPoint(x: 1, y: 1))
        case "shadow": selection.shadowTip = NormalizedPoint(x: 0.7, y: 0.95)
        case "colours": selection.colours = ["white"]
        case "single": instances = [instances[0]]
        case "not-every": selection.every = false
        case "crop": prefix = [.crop(Crop(rect: .whole))]
        case "ordinary": prompt = "Replace the shirts with leather armour"
        case "user-pattern": instruction = "Make the shirts blue and keep their striped pattern"
        case "different-colours": instruction = "Make the left shirt blue and the right shirt red"
        default: break
        }
        let agent = MaterialFixture.agent(host: host, generator: generator, selection: selection, prefix: prefix,
                                         prompt: prompt, instances: instances)
        _ = try await materialEvents(agent.run(instruction, area: area))
        #expect(await host.inputs.isEmpty)
        #expect(!(await generator.requests).isEmpty, "The established transformation path remains available")
    }

    @Test(arguments: ["blue", "red", "green", "yellow", "purple", "pink", "brown", "black", "white", "teal"])
    func naturalColourRequestsDoNotRequirePrototypeMagicWords(_ colour: String) async throws {
        let host = MaterialTestHost(.accepted)
        let prompt = "Make all four shirts \(colour), preserving their fabric texture, folds and logos"
        let instruction = "Make the shirts in these selected photos \(colour)"
        _ = try await materialEvents(MaterialFixture.agent(host: host, prompt: prompt).run(instruction))
        #expect(await host.inputs.count == 1)
        #expect(await host.legacyCalls == 0)
    }

    @Test func laterAreaRequestCannotReuseBroadMaterialInstances() async throws {
        let host = MaterialTestHost(.accepted)
        let agent = EditAgent(planner: MaterialReusePlanner(),
                              segmenter: MaterialTestSegmenter(instances: MaterialFixture.instances),
                              generator: MaterialTestGenerator(), host: host,
                              configuration: AgentConfiguration(maxRevisions: 0))
        _ = try await materialEvents(agent.run(Self.instruction))
        #expect(await host.inputs.isEmpty)
        _ = try await materialEvents(agent.run(Self.instruction, area: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(await host.inputs.isEmpty, "An earlier whole-photo region cannot authorize broad instance transfer for an area request")
        #expect(await host.legacyCalls == 1)
    }

    @Test(arguments: [false, true]) func errorsDoNotSilentlyFallBackAndCancellationPropagates(cancel: Bool) async throws {
        let host = MaterialTestHost(cancel ? .cancelled : .failed)
        let agent = MaterialFixture.agent(host: host, satisfied: false)
        if cancel {
            await #expect(throws: LumenError.cancelled) { _ = try await materialEvents(agent.run(Self.instruction)) }
        } else {
            let events = try await materialEvents(agent.run(Self.instruction))
            #expect(events.contains { if case .trace(let trace) = $0 { trace.kind == .failure && trace.detail.contains("stale material source") } else { false } })
        }
        #expect(await host.inputs.count == 1)
        #expect(await host.legacyCalls == 0)
        #expect(await host.layers.isEmpty)
    }

    @Test func modelSolidExpansionCannotOverrideOriginalColourOrPatternConstraints() {
        #expect(EditAgent.isMaterialRecolourPrompt(Self.wording, instruction: Self.instruction))
        for original in ["Give the shirts different colours", "Make them a blue gradient", "Keep their plaid pattern and make it blue", "Make the left one blue and the right one green", "Make them festive"] {
            #expect(!EditAgent.isMaterialRecolourPrompt(Self.wording, instruction: original))
        }
        for prompt in ["Recolour shirts solid red", "Recolour shirts solid blue and red", "Recolour shirts solid blue and reshape the sleeves"] {
            #expect(!EditAgent.isMaterialRecolourPrompt(prompt, instruction: Self.instruction))
        }
    }
}

private func materialEvents(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var result: [AgentEvent] = []; for try await event in stream { result.append(event) }; return result
}

private enum MaterialFixture {
    static let size = PixelSize(width: 64, height: 48)
    static let original = EncodedImage(data: Data("original crop".utf8), format: .png, size: size)
    static let generated = EncodedImage(data: Data("provider generated".utf8), format: .png, size: size)
    static let instances: [MaskData] = [2, 18, 34, 50].map { left in
        var mask = MaskData(size: size, filledWith: 0)
        for y in 6..<42 { for x in left..<(left + 12) { mask.coverage[y * size.width + x] = x == left ? 96 : 255 } }
        return mask
    }
    static var union: MaskData { instances.dropFirst().reduce(instances[0]) { $0.union($1) } }
    static func agent(host: any EditHost, generator: MaterialTestGenerator = MaterialTestGenerator(),
                      selection: Selection = Selection(id: "shirts", concept: "t-shirt", every: true),
                      prefix: [EditStep] = [], prompt: String = MaterialRecolourIntegrationTests.wording,
                      instances: [MaskData] = instances, satisfied: Bool = true) -> EditAgent {
        let steps = prefix + [.select(selection), .regenerate(Regeneration(region: selection.id, prompt: prompt))]
        return EditAgent(planner: MaterialTestPlanner(steps: steps, satisfied: satisfied),
                         segmenter: MaterialTestSegmenter(instances: instances), generator: generator, host: host,
                         configuration: AgentConfiguration(maxRevisions: 0))
    }
}

private struct MaterialTestPlanner: Planner {
    let modelID = "recorded planner"
    let steps: [EditStep]
    let satisfied: Bool
    func plan(_ request: PlanRequest) async throws -> EditPlan { EditPlan(summary: "Recolour shirts", steps: steps) }
    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: satisfied, notes: "Checked") }
}
private actor MaterialReusePlanner: Planner {
    let modelID = "recorded region-reuse planner"
    private var calls = 0
    func plan(_ request: PlanRequest) async throws -> EditPlan {
        calls += 1
        let steps: [EditStep] = calls == 1
            ? [.select(Selection(id: "shirts", concept: "t-shirt", every: true))]
            : [.regenerate(Regeneration(region: "shirts", prompt: MaterialRecolourIntegrationTests.wording))]
        return EditPlan(summary: "Recolour shirts", steps: steps)
    }
    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Checked") }
}
private struct MaterialTestSegmenter: Segmenter {
    let modelID = "recorded SAM"
    let instances: [MaskData]
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        instances.compactMap { mask in mask.boundingBox.map { Segment(label: "shirt", box: $0, mask: mask) } }
    }
}
private actor MaterialTestGenerator: Generator {
    let modelID = "recorded image"
    private(set) var requests: [GenerateRequest] = []
    func generate(_ request: GenerateRequest) async throws -> EncodedImage { requests.append(request); return MaterialFixture.generated }
}
private actor MaterialTestHost: EditHost {
    enum Mode { case accepted, declined, failed, cancelled }
    struct Input: Sendable { let generated: EncodedImage; let original: EncodedImage; let region: NormalizedRect; let instances: [MaskData] }
    let mode: Mode
    let cropSize: PixelSize
    private(set) var inputs: [Input] = []
    private(set) var legacyCalls = 0
    private(set) var layers: [Layer] = []
    init(_ mode: Mode, cropSize: PixelSize = MaterialFixture.size) { self.mode = mode; self.cropSize = cropSize }
    func size() async -> PixelSize { MaterialFixture.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { MaterialFixture.original }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: MaterialFixture.original.data, format: .png, size: cropSize)
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws { layers.append(layer) }
    func remove(_ layer: Layer.ID) async throws { layers.removeAll { $0.id == layer } }
    func materialRecolour(_ generated: EncodedImage, over original: EncodedImage, in region: NormalizedRect,
                          instances: [MaskData]) async throws -> PreparedPatch? {
        inputs.append(Input(generated: generated, original: original, region: region, instances: instances))
        switch mode {
        case .declined: return nil
        case .failed: throw LumenError.invalidResponse("stale material source")
        case .cancelled: throw LumenError.cancelled
        case .accepted:
            return PreparedPatch(image: EncodedImage(data: Data("material prepared".utf8), format: .png, size: original.size),
                                 mask: instances.dropFirst().reduce(instances[0]) { $0.union($1) })
        }
    }
    func recolourEdges(_ generated: EncodedImage, over original: EncodedImage, within mask: MaskData) async throws -> PreparedPatch? {
        legacyCalls += 1
        return PreparedPatch(image: EncodedImage(data: Data("legacy prepared".utf8), format: .png, size: original.size), mask: mask)
    }
}
private struct MaterialLegacyHost: EditHost {
    let base: MaterialTestHost
    func size() async -> PixelSize { await base.size() }
    func render(maxLongEdge: Int) async throws -> EncodedImage { try await base.render(maxLongEdge: maxLongEdge) }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage { try await base.render(region: region, maxLongEdge: maxLongEdge) }
    func apply(_ layer: Layer, assets: AssetStore) async throws { try await base.apply(layer, assets: assets) }
    func remove(_ layer: Layer.ID) async throws { try await base.remove(layer) }
    func recolourEdges(_ generated: EncodedImage, over original: EncodedImage, within mask: MaskData) async throws -> PreparedPatch? {
        try await base.recolourEdges(generated, over: original, within: mask)
    }
}
