import Foundation
import Testing
import LumenCore

@Suite("Object selection fallback")
struct SelectionFallbackTests {
    @Test func aPlannerBoxBecomesAnObjectPromptAfterBothNameSearchesMiss() async throws {
        let box = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let points = [NormalizedPoint(x: 0.5, y: 0.5)]
        let result = try await select(Selection(id: "gate", concept: "red gate", box: box, points: points))
        let requests = await result.segmenter.requests
        #expect(requests.map(\.concept) == ["red gate", "red gate", nil])
        #expect(requests.map(\.box) == [box, nil, box])
        #expect(requests.allSatisfy { $0.points == points })
        let selected = try #require(result.events.compactMap { event -> Segment? in
            if case .selected(_, let segment) = event { segment } else { nil }
        }.first)
        #expect(selected.label == "red gate")
        #expect(selected.mask == SelectionPhoto.mask)
        #expect(selected.score == 0.87)
        #expect(await result.planner.regions == [RegionInfo(id: "gate", concept: "red gate",
                                                          box: .whole, area: 1)])
        #expect(await result.host.layers.count == 1)
        #expect(result.events.contains { event in
            if case .trace(let trace) = event {
                trace.kind == .select && trace.model == nil && trace.detail.contains("by name")
                    && trace.detail.contains("planner's box")
            } else { false }
        })
    }

    @Test func aUserAreaGivesTheSecondRequestAnObjectPrompt() async throws {
        let area = NormalizedRect(x: 0, y: 0.2, width: 1, height: 0.6)
        let result = try await select(Selection(id: "gate", concept: "gate"), area: area)
        let requests = await result.segmenter.requests
        #expect(requests.map(\.concept) == ["gate", nil])
        #expect(requests.map(\.box) == [area, area])
        #expect(await result.host.layers.count == 1)
    }

    @Test func pointsAloneGiveTheSecondRequestAnObjectPrompt() async throws {
        let points = [NormalizedPoint(x: 0.4, y: 0.6)]
        let result = try await select(Selection(id: "gate", concept: "gate", points: points))
        let requests = await result.segmenter.requests
        #expect(requests.map(\.concept) == ["gate", nil])
        #expect(requests.allSatisfy { $0.box == nil && $0.points == points })
        #expect(await result.host.layers.count == 1)
    }

    @Test func noObjectPromptIsTriedWithoutGeometry() async throws {
        let result = try await select(Selection(id: "gate", concept: "gate"))
        #expect(await result.segmenter.requests.count == 1)
        #expect(await result.host.layers.isEmpty)
        #expect(await result.planner.regions.isEmpty)
    }

    @Test func anEmptyObjectPromptStillSkipsTheAdjustment() async throws {
        let result = try await select(Selection(id: "gate", concept: "gate", box: .whole), found: false)
        #expect(await result.segmenter.requests.map(\.concept) == ["gate", "gate", nil])
        #expect(await result.host.layers.isEmpty)
        #expect(await result.planner.regions.isEmpty)
    }

    @Test func aSelectionAlreadyUsingObjectPromptsIsNotRetried() async throws {
        let result = try await select(Selection(id: "gate", box: .whole), found: false)
        #expect(await result.segmenter.requests.count == 1)
    }

    private func select(_ selection: Selection, area: NormalizedRect? = nil, found: Bool = true) async throws
        -> (events: [AgentEvent], segmenter: ObjectSegmenter, planner: SelectionPlanner, host: SelectionHost) {
        let segmenter = ObjectSegmenter(found: found)
        let planner = SelectionPlanner(selection: selection)
        let host = SelectionHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: SelectionGenerator(), host: host)
        var events: [AgentEvent] = []
        for try await event in agent.run("Make the gate stand out", area: area) { events.append(event) }
        return (events, segmenter, planner, host)
    }
}

private actor ObjectSegmenter: Segmenter {
    let modelID = "sam-3.1"
    let found: Bool
    private(set) var requests: [SegmentRequest] = []

    init(found: Bool) { self.found = found }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        guard request.concept == nil, found else { return [] }
        return [Segment(label: "", box: .whole, mask: SelectionPhoto.mask, score: 0.87)]
    }
}

private actor SelectionPlanner: Planner {
    let modelID = "muse-spark-1.3"
    let selection: Selection
    private(set) var regions: [RegionInfo] = []

    init(selection: Selection) { self.selection = selection }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        EditPlan(summary: "Emphasize the gate", steps: [
            .select(selection), .adjust(Adjustment(region: selection.id, values: [.exposure: 0.5])),
        ])
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        regions = request.regions
        return Critique(satisfied: true, notes: "Checked.")
    }
}

private actor SelectionHost: EditHost {
    private(set) var layers: [Layer] = []

    func size() async -> PixelSize { SelectionPhoto.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { SelectionPhoto.image }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage { SelectionPhoto.image }
    func apply(_ layer: Layer, assets: AssetStore) async throws { layers.append(layer) }
    func remove(_ layer: Layer.ID) async throws { layers.removeAll { $0.id == layer } }
}

private struct SelectionGenerator: Generator {
    let modelID = "muse-image-1.0"

    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        throw LumenError.invalidResponse("Selection adjustments do not redraw the photo.")
    }
}

private enum SelectionPhoto {
    static let size = PixelSize(width: 2, height: 2)
    static let image = EncodedImage(data: Data(), format: .png, size: size)
    static let mask = MaskData(size: size, filledWith: 255)
}
