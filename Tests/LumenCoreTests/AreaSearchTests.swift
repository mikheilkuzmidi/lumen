import Foundation
import Testing
import LumenCore

@Suite("Search inside a marked area")
struct AreaSearchTests {
    private static let image = EncodedImage(data: Data([1]), format: .jpeg, size: PixelSize(width: 10, height: 10))
    private static let area = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)

    /// A 10 × 10 mask covering the given pixel columns and rows.
    private static func mask(x: Range<Int>, y: Range<Int>) -> MaskData {
        var coverage = [UInt8](repeating: 0, count: 100)
        for row in y { for column in x { coverage[row * 10 + column] = 255 } }
        return MaskData(size: PixelSize(width: 10, height: 10), coverage: coverage)
    }

    private static func segment(_ mask: MaskData) -> Segment {
        Segment(label: "shirt", box: mask.boundingBox ?? .whole, mask: mask)
    }

    @Test func thingsByNameInsideTheAreaAreKeptAndUnited() async throws {
        let inside = Self.mask(x: 0..<2, y: 0..<2), alsoInside = Self.mask(x: 3..<5, y: 3..<5)
        let outside = Self.mask(x: 6..<10, y: 6..<10)
        let segmenter = AreaSegmenter(answers: [[inside, alsoInside, outside].map(Self.segment)])
        let found = try #require(try await AreaSearch(segmenter: segmenter).find("shirt", in: Self.image, area: Self.area))
        #expect(found.method == .name)
        #expect(found.count == 2)
        #expect(found.mask == inside.union(alsoInside))
        let requests = await segmenter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.concept == "shirt")
        #expect(requests.first?.box == Self.area)
    }

    @Test func aThingMostlyOutsideTheAreaIsNotThere() async throws {
        // Two of its eight pixels lie inside.
        let straddling = Self.mask(x: 4..<8, y: 3..<5)
        let segmenter = AreaSegmenter(answers: [[Self.segment(straddling)], []])
        #expect(try await AreaSearch(segmenter: segmenter).find("shirt", in: Self.image, area: Self.area) == nil)
        #expect(await segmenter.requests.count == 2)
    }

    @Test func whenNothingByNameIsThereTheAreaBecomesTheObjectPrompt() async throws {
        let framed = Self.mask(x: 1..<4, y: 1..<4)
        let segmenter = AreaSegmenter(answers: [[], [Self.segment(framed)]])
        let found = try #require(try await AreaSearch(segmenter: segmenter).find("gate", in: Self.image, area: Self.area))
        #expect(found.method == .area)
        #expect(found.count == 1)
        #expect(found.mask == framed)
        let requests = await segmenter.requests
        #expect(requests.map(\.concept) == ["gate", nil])
        #expect(requests.map(\.box) == [Self.area, Self.area])
    }

    @Test func withoutAnAreaOnlyTheNameIsSearched() async throws {
        let segmenter = AreaSegmenter(answers: [[]])
        #expect(try await AreaSearch(segmenter: segmenter).find("gate", in: Self.image, area: nil) == nil)
        let requests = await segmenter.requests
        #expect(requests.count == 1)
        #expect(requests.first?.box == nil)
    }

    @Test func emptyMasksCountForNothing() async throws {
        let empty = MaskData(size: PixelSize(width: 10, height: 10), filledWith: 0)
        let segmenter = AreaSegmenter(answers: [[Self.segment(empty)], [Self.segment(empty)]])
        #expect(try await AreaSearch(segmenter: segmenter).find("gate", in: Self.image, area: Self.area) == nil)
    }

    @Test func shareInsideCountsCoverageNotPixels() {
        var coverage = [UInt8](repeating: 0, count: 4)
        coverage[0] = 255; coverage[3] = 85
        let mask = MaskData(size: PixelSize(width: 2, height: 2), coverage: coverage)
        let topLeft = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(abs(mask.share(inside: topLeft) - 0.75) < 1e-9)
        #expect(MaskData(size: PixelSize(width: 2, height: 2), filledWith: 0).share(inside: topLeft) == 0)
    }
}

/// Answers each request with the next scripted list of segments.
private actor AreaSegmenter: Segmenter {
    nonisolated let modelID = "sam-test"
    private var answers: [[Segment]]
    private(set) var requests: [SegmentRequest] = []

    init(answers: [[Segment]]) { self.answers = answers }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        return answers.isEmpty ? [] : answers.removeFirst()
    }
}
