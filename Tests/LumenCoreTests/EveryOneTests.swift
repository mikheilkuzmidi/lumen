import Foundation
import Testing
@testable import LumenCore

/// The flowers and sails were missed: the planner pointed at a few with points that missed small things, and only what
/// lay under them was kept. A selection can now mean every one SAM finds, kept by colour when asked.
@Suite("Every one of a kind", .timeLimit(.minutes(1)))
struct EveryOneTests {
    /// Three flowers in a 12 × 4 photo: orange at columns 0..<3, red at 4..<7, yellow at 8..<11.
    static func flower(_ columns: Range<Int>) -> Segment {
        let mask = MaskData(size: PixelSize(width: 12, height: 4), coverage: (0..<48).map { columns.contains($0 % 12) ? 255 : 0 })
        return Segment(label: "flower", box: mask.boundingBox!, mask: mask)
    }
    static let orange = flower(0..<3), red = flower(4..<7), yellow = flower(8..<11)

    @Test func everyOneIsFoundAndKeptByColour() async throws {
        let planner = FlowerPlanner(plan: EditPlan(summary: "Purple flowers", steps: [
            .select(Selection(id: "flowers", concept: "flower", box: NormalizedRect(x: 0, y: 0, width: 0.2, height: 1),
                              points: [NormalizedPoint(x: 0.05, y: 0.5)], every: true, colours: ["orange", "yellow"])),
            .adjust(Adjustment(region: "flowers", values: [.saturation: 20])),
        ]))
        let segmenter = FlowerSegmenter(answers: [[Self.orange, Self.red, Self.yellow]])
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: FlowerGenerator(), host: FlowerHost())
        var masks: [MaskData] = []
        var notes: [String] = []
        for try await event in agent.run("Make the orange flowers purple") {
            if case .selected(_, let segment) = event { masks.append(segment.mask) }
            if case .trace(let trace) = event, trace.model == nil { notes.append(trace.detail) }
        }
        // Searched over the whole photo, not at the planner's point or box, and the red one left out.
        let request = try #require(await segmenter.requests.first)
        #expect(request.concept == "flower" && request.box == nil && request.points.isEmpty)
        #expect(masks == [Self.orange.mask.union(Self.yellow.mask)])
        #expect(notes.contains("Of 3 found, 2 are orange or yellow (the others: red)."))
        #expect(notes.contains("Found 2 flower for flowers."))
    }

    @Test func everyOneWithoutColoursKeepsAllThatIsFound() async throws {
        let planner = FlowerPlanner(plan: EditPlan(summary: "Red sails", steps: [
            .select(Selection(id: "sails", concept: "flower", box: NormalizedRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1), every: true)),
            .adjust(Adjustment(region: "sails", values: [.saturation: 20])),
        ]))
        let segmenter = FlowerSegmenter(answers: [[Self.orange, Self.red, Self.yellow]])
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: FlowerGenerator(), host: FlowerHost())
        var masks: [MaskData] = []
        for try await event in agent.run("Make the sails red") {
            if case .selected(_, let segment) = event { masks.append(segment.mask) }
        }
        // A box that misses them all (as the planner's did for the sails) no longer throws them away.
        #expect(masks == [Self.orange.mask.union(Self.red.mask).union(Self.yellow.mask)])
    }

    @Test func aRedrawOfSeveralThingsIsCheckedAgainstAllOfThem() async throws {
        let planner = FlowerPlanner(plan: EditPlan(summary: "Purple flowers", steps: [
            .select(Selection(id: "flowers", concept: "flower", every: true)),
            .regenerate(Regeneration(region: "flowers", prompt: "Purple flowers")),
        ]))
        // SAM finds the two flowers again in the redraw, one by one: together they are where the flowers were.
        let segmenter = FlowerSegmenter(answers: [[Self.orange, Self.yellow], [Self.orange, Self.yellow]])
        let generator = FlowerGenerator()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: FlowerHost())
        var notes: [String] = []
        for try await event in agent.run("Make the flowers purple") {
            if case .trace(let trace) = event { notes.append(trace.detail) }
        }
        #expect(await generator.count == 1, "no second redraw")
        #expect(await generator.prompts.first?.contains("This is for all 2 of these flowers in the picture") == true)
        #expect(!notes.contains { $0.contains("moved or resized") })
    }

    @Test func coloursAreNamedByFamily() {
        #expect(EditAgent.family(of: ColourMeasurement(lightness: 60, a: 30, b: 60)) == "orange")
        #expect(EditAgent.family(of: ColourMeasurement(lightness: 30, a: -14, b: -6)) == "teal")
        #expect(EditAgent.family(of: ColourMeasurement(lightness: 20, a: 1, b: 1)) == "black")
        #expect(EditAgent.family(of: ColourMeasurement(lightness: 80, a: 1, b: 1)) == "grey")
        #expect(EditAgent.family(of: ColourMeasurement(lightness: 40, a: 15, b: 30)) == "brown")
        // An orange poppy in shade names as brown, but is orange by hue.
        let shaded = ColourMeasurement(lightness: 42, a: 14, b: 32)
        #expect(shaded.family == "brown" && shaded.isIn("orange") && !shaded.isIn("blue"))
        #expect(!ColourMeasurement(lightness: 50, a: 2, b: 3).isIn("orange"), "grey is no hue")
    }

    @Test func thePlanCheckKeepsOnlyColourFamiliesAndNeedsAConcept() {
        let checked = EditPlan(summary: "Flowers", steps: [
            .select(Selection(id: "flowers", concept: "flower", every: true, colours: [" Orange", "gold", "yellow", "orange"])),
            .select(Selection(id: "area", box: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5), every: true, colours: ["red"])),
        ]).checked()
        #expect(checked.plan.steps == [
            .select(Selection(id: "flowers", concept: "flower", every: true, colours: ["orange", "yellow"])),
            .select(Selection(id: "area", box: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))),
        ])
        #expect(checked.notes.contains { $0.contains("not colour families") })
        #expect(checked.notes.contains { $0.contains("needs a concept") })
    }
}

private actor FlowerPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private let answer: EditPlan
    init(plan: EditPlan) { answer = plan }
    func plan(_ request: PlanRequest) async throws -> EditPlan { answer }
    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Done.") }
}

private actor FlowerSegmenter: Segmenter {
    let modelID = "sam-3.1"
    private var answers: [[Segment]]
    private(set) var requests: [SegmentRequest] = []
    init(answers: [[Segment]]) { self.answers = answers }
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        return answers.isEmpty ? [] : answers.removeFirst()
    }
}

private actor FlowerGenerator: Generator {
    let modelID = "muse-image-1.0"
    private(set) var count = 0
    private(set) var prompts: [String] = []
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        count += 1
        prompts.append(request.prompt)
        return request.image
    }
}

/// A 12 × 4 photo whose renders and crops are 12 × 4, measuring each flower's colour by where its mask lies.
private actor FlowerHost: EditHost {
    private var layers: [Layer] = []
    func size() async -> PixelSize { PixelSize(width: 12, height: 4) }
    func render(maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([UInt8(layers.count)]), format: .png, size: PixelSize(width: 12, height: 4))
    }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: 12, height: 4))
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws { layers.append(layer) }
    func remove(_ layer: Layer.ID) async throws { layers.removeAll { $0.id == layer } }
    func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? {
        guard let mask, let left = (0..<mask.size.width).first(where: { mask[$0, 1] > 127 }) else {
            return ColourMeasurement(lightness: 50, a: 0, b: 0)
        }
        switch left {
        case 0..<4: return ColourMeasurement(lightness: 60, a: 30, b: 60)   // orange
        case 4..<8: return ColourMeasurement(lightness: 45, a: 60, b: 35)   // red
        default: return ColourMeasurement(lightness: 85, a: -5, b: 80)      // yellow
        }
    }
}
