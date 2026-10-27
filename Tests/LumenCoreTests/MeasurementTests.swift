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

    func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? {
        guard measures else { return nil }
        measured.append((image, mask))
        let covered = mask?.coverage.filter { $0 > 127 }.count ?? 100
        return Self.colour(layers: Int(image.data.first ?? 0), covered: covered)
    }
}
