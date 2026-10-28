import Foundation
import Testing
@testable import LumenCore

@Suite("Measured critique", .timeLimit(.minutes(1)))
struct MeasurementTests {
    @Test func coloursAreNamedAsAPersonWouldSayThem() {
        #expect(ColourMeasurement(lightness: 10, a: 1, b: -2).name == "black")
        // The cup asked for matte black on October 26 read 20: too light to be black.
        #expect(ColourMeasurement(lightness: 20, a: -2, b: -3).name == "charcoal")
        #expect(ColourMeasurement(lightness: 55, a: 2, b: 3).name == "grey")
        #expect(ColourMeasurement(lightness: 95, a: 0, b: 2).name == "white")
        // The cup that came out "dark teal rather than black" on October 26.
        #expect(ColourMeasurement(lightness: 30, a: -14, b: -6).name == "muted dark teal")
        #expect(ColourMeasurement(lightness: 30, a: 20, b: -50).name == "dark blue")
        #expect(ColourMeasurement(lightness: 55, a: 70, b: 55).name == "red")
        #expect(ColourMeasurement(lightness: 85, a: -5, b: 80).name == "light yellow")
        #expect(ColourMeasurement(lightness: 40, a: 15, b: 30).name == "brown")
        #expect(ColourMeasurement(lightness: 60, a: -45, b: 35).name == "green")
    }

    @Test func aChangeIsMeasuredAsTheEyeSeesIt() {
        let before = ColourMeasurement(lightness: 50, a: 0, b: 0)
        #expect(RegionChange(region: "face", before: before, after: ColourMeasurement(lightness: 52, a: 0, b: 0)).change == 2)
        #expect(RegionChange(region: "cup", before: before, after: ColourMeasurement(lightness: 47, a: 4, b: 0)).change == 5)
        #expect(abs(ColourMeasurement(lightness: 50, a: 0, b: 10).hue - 90) < 1e-9)
        #expect(abs(ColourMeasurement(lightness: 50, a: 0, b: -10).hue - 270) < 1e-9)
    }

    @Test func theCriticGetsEachChangedRegionAndTheRestOfThePhoto() async throws {
        let planner = MeasuredPlanner(plan: EditPlan(summary: "Darken the cup", steps: [
            .select(Selection(id: "cup", concept: "cup")),
            .select(Selection(id: "table", concept: "table")),
            .adjust(Adjustment(region: "cup", values: [.exposure: -1])),
        ]))
        let host = MeasuringHost()
        let agent = EditAgent(planner: planner, segmenter: MeasuredSegmenter(), generator: MeasuredGenerator(), host: host)
        for try await _ in agent.run("Make the cup darker") {}
        let request = try #require(await planner.critiques.first)
        // The table was selected but not changed, so it is only part of the rest.
        #expect(request.measurements.map(\.region) == ["cup", "rest of the photo"])
        let cup = try #require(request.measurements.first)
        #expect(cup.before == MeasuringHost.colour(layers: 0, covered: MeasuringHost.cup))
        #expect(cup.after == MeasuringHost.colour(layers: 1, covered: MeasuringHost.cup))
        let measured = await host.measured
        #expect(measured.count == 4)
        #expect(measured[2].mask == MeasuredSegmenter.cup.inverted(), "the rest is everything outside the cup")
    }

    @Test func aWholePhotoEditIsMeasuredOverTheWholePhoto() async throws {
        let planner = MeasuredPlanner(plan: EditPlan(summary: "Warm it", steps: [.adjust(Adjustment(values: [.temperature: 20]))]))
        let host = MeasuringHost()
        let agent = EditAgent(planner: planner, segmenter: MeasuredSegmenter(), generator: MeasuredGenerator(), host: host)
        for try await _ in agent.run("Warm it up") {}
        let request = try #require(await planner.critiques.first)
        #expect(request.measurements.map(\.region) == ["photo"])
        #expect(await host.measured.allSatisfy { $0.mask == nil })
    }

    @Test func aHostThatCannotMeasureLeavesTheCriticItsEyes() async throws {
        let planner = MeasuredPlanner(plan: EditPlan(summary: "Darken the cup", steps: [
            .select(Selection(id: "cup", concept: "cup")), .adjust(Adjustment(region: "cup", values: [.exposure: -1])),
        ]))
        let agent = EditAgent(planner: planner, segmenter: MeasuredSegmenter(), generator: MeasuredGenerator(),
                              host: MeasuringHost(measures: false))
        for try await _ in agent.run("Make the cup darker") {}
        #expect(try #require(await planner.critiques.first).measurements.isEmpty)
    }

    @Test func aCropInTheRunLeavesNothingToCompare() async throws {
        let planner = MeasuredPlanner(plan: EditPlan(summary: "Crop and darken", steps: [
            .select(Selection(id: "cup", concept: "cup")), .adjust(Adjustment(region: "cup", values: [.exposure: -1])),
            .crop(Crop(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))),
        ]))
        let host = MeasuringHost()
        let agent = EditAgent(planner: planner, segmenter: MeasuredSegmenter(), generator: MeasuredGenerator(), host: host)
        for try await _ in agent.run("Crop it and darken the cup") {}
        #expect(try #require(await planner.critiques.first).measurements.isEmpty)
        #expect(await host.measured.isEmpty)
    }
}

@Suite("Gradient light", .timeLimit(.minutes(1)))
struct GradientTests {
    @Test func lightFromOneSideNeedsNoSearch() async throws {
        let light = Gradient(from: NormalizedPoint(x: 1, y: 0.4), to: NormalizedPoint(x: 0.2, y: 0.7))
        let planner = MeasuredPlanner(plan: EditPlan(summary: "Low sun from the right", steps: [
            .select(Selection(id: "sun", gradient: light)),
            .adjust(Adjustment(region: "sun", values: [.exposure: 0.3, .highlightWarmth: 40])),
        ]))
        let segmenter = CountingSegmenter()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: MeasuredGenerator(), host: MeasuringHost())
        var masks: [MaskData] = []
        for try await event in agent.run("Make it feel like golden hour") {
            if case .selected(_, let segment) = event { masks.append(segment.mask) }
        }
        #expect(await segmenter.count == 0, "no SAM call")
        #expect(masks == [MaskData.gradient(size: PixelSize(width: 10, height: 10), from: light.from, to: light.to)])
        let request = try #require(await planner.critiques.first)
        #expect(request.regions.map(\.id) == ["sun"] && request.done.contains("Sun: selected"))
    }

    @Test func whatIsFoundFadesAlongTheGradient() async throws {
        let light = Gradient(from: NormalizedPoint(x: 1, y: 0.5), to: NormalizedPoint(x: 0, y: 0.5))
        let planner = MeasuredPlanner(plan: EditPlan(summary: "Warm the sky near the sun", steps: [
            .select(Selection(id: "sky", concept: "cup", gradient: light)),
            .adjust(Adjustment(region: "sky", values: [.highlightWarmth: 40])),
        ]))
        let agent = EditAgent(planner: planner, segmenter: MeasuredSegmenter(), generator: MeasuredGenerator(), host: MeasuringHost())
        var masks: [MaskData] = []
        for try await event in agent.run("Warm the sky near the sun") {
            if case .selected(_, let segment) = event { masks.append(segment.mask) }
        }
        let cup = MeasuredSegmenter.cup
        #expect(masks == [cup.multiplied(by: MaskData.gradient(size: cup.size, from: light.from, to: light.to))])
        #expect(masks[0][4, 5] > masks[0][2, 5], "brighter toward the light")
    }
}

@Suite("Lost detail", .timeLimit(.minutes(1)))
struct LostDetailTests {
    @Test func theCriticIsToldWhereARedrawLostItsDetail() async throws {
        let planner = MeasuredPlanner(plan: EditPlan(summary: "A red cup", steps: [
            .select(Selection(id: "cup", concept: "cup")),
            .regenerate(Regeneration(region: "cup", prompt: "A red cup")),
        ]))
        let agent = EditAgent(planner: planner, segmenter: MeasuredSegmenter(), generator: MeasuredGenerator(), host: MeasuringHost())
        for try await _ in agent.run("Make the cup red") {}
        let closeUp = try #require(await planner.critiques.first?.closeUps.first)
        #expect(closeUp.region == "cup" && closeUp.lostDetail == MeasuringHost.lost)
        // The recolour's mask is grown over the same colour by the host.
        #expect(await MeasuringHost.extendedCalls.value > 0)
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}

@Suite("Cast shadows", .timeLimit(.minutes(1)))
struct CastShadowTests {
    @Test func theRegionIsTheShadowWhatIsFoundCasts() async throws {
        let tip = NormalizedPoint(x: 0.95, y: 0.9)
        let planner = MeasuredPlanner(plan: EditPlan(summary: "The cup's long shadow", steps: [
            .select(Selection(id: "shadow", concept: "cup", invert: true, shadowTip: tip)),
            .adjust(Adjustment(region: "shadow", values: [.exposure: -0.6])),
        ]))
        let agent = EditAgent(planner: planner, segmenter: MeasuredSegmenter(), generator: MeasuredGenerator(), host: MeasuringHost())
        var masks: [MaskData] = []
        for try await event in agent.run("Low sun from the left") {
            if case .selected(_, let segment) = event { masks.append(segment.mask) }
        }
        #expect(masks == [MeasuredSegmenter.cup.castShadow(tip: tip)], "the shadow, not the cup or its inverse")
    }
}

private actor CountingSegmenter: Segmenter {
    let modelID = "sam-3.1"
    private(set) var count = 0
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        count += 1
        return []
    }
}

private actor MeasuredPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private let answer: EditPlan
    private(set) var critiques: [CritiqueRequest] = []

    init(plan: EditPlan) { answer = plan }

    func plan(_ request: PlanRequest) async throws -> EditPlan { answer }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiques.append(request)
        return Critique(satisfied: true, notes: "Done.")
    }
}

private struct MeasuredSegmenter: Segmenter {
    let modelID = "sam-3.1"
    static let cup = mask(columns: 2..<5)
    static let table = mask(columns: 6..<9)

    static func mask(columns: Range<Int>) -> MaskData {
        MaskData(size: PixelSize(width: 10, height: 10),
                 coverage: (0..<100).map { columns.contains($0 % 10) ? 255 : 0 })
    }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        let mask = request.concept == "cup" ? Self.cup : Self.table
        return [Segment(label: request.concept ?? "thing", box: mask.boundingBox!, mask: mask)]
    }
}

private struct MeasuredGenerator: Generator {
    let modelID = "muse-image-1.0"
    func generate(_ request: GenerateRequest) async throws -> EncodedImage { request.image }
}

/// Renders the layer count into the image size, and measures a colour from that count and the mask's coverage.
private actor MeasuringHost: EditHost {
    static let cup = 30
    private let measures: Bool
    private var layers: [Layer] = []
    private(set) var measured: [(image: EncodedImage, mask: MaskData?)] = []

    init(measures: Bool = true) { self.measures = measures }

    static func colour(layers: Int, covered: Int) -> ColourMeasurement {
        ColourMeasurement(lightness: 60 - Double(layers) * 20, a: Double(covered), b: 0)
    }

    func size() async -> PixelSize { PixelSize(width: 10, height: 10) }

    func render(maxLongEdge: Int) async throws -> EncodedImage {
        let cropped = layers.contains { if case .crop = $0.content { true } else { false } }
        return EncodedImage(data: Data([UInt8(layers.count)]), format: .png,
                            size: PixelSize(width: cropped ? 5 : 10, height: 10))
    }

    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: 4, height: 4))
    }

    func apply(_ layer: Layer, assets: AssetStore) async throws { layers.append(layer) }

    func remove(_ layer: Layer.ID) async throws { layers.removeAll { $0.id == layer } }

    static let lost = [LostDetail(rect: NormalizedRect(x: 0.2, y: 0.4, width: 0.1, height: 0.1), kept: 0.12)]
    static let extendedCalls = Counter()

    func extended(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        await Self.extendedCalls.add()
        return mask
    }

    func lostDetail(before: EncodedImage, after: EncodedImage) async throws -> [LostDetail] { Self.lost }

    func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? {
        guard measures else { return nil }
        measured.append((image, mask))
        let covered = mask?.coverage.filter { $0 > 127 }.count ?? 100
        return Self.colour(layers: Int(image.data.first ?? 0), covered: covered)
    }
}
