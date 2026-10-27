import Foundation
import Testing
import LumenCore

@Suite("Segmentation cache")
struct CachingSegmenterTests {
    private static func image(_ byte: UInt8) -> EncodedImage { EncodedImage(data: Data([byte]), format: .jpeg, size: PixelSize(width: 2, height: 2)) }
    private static let found = [Segment(label: "cup", box: .whole, mask: MaskData(size: PixelSize(width: 2, height: 2), filledWith: 255))]

    @Test func theSameAskOnTheSamePictureIsAnsweredOnce() async throws {
        let counter = CountingSegmenter(answer: Self.found)
        let cache = CachingSegmenter(counter)
        let ask = SegmentRequest(image: Self.image(1), concept: "cup", box: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(try await cache.segment(ask) == Self.found)
        #expect(try await cache.segment(ask) == Self.found)
        #expect(await counter.calls == 1)
        let hits = await cache.hits, misses = await cache.misses
        #expect(hits == 1 && misses == 1)
        #expect(cache.modelID == "sam-test")
    }

    @Test func anyDifferenceIsANewAsk() async throws {
        let counter = CountingSegmenter(answer: Self.found)
        let cache = CachingSegmenter(counter)
        _ = try await cache.segment(SegmentRequest(image: Self.image(1), concept: "cup"))
        _ = try await cache.segment(SegmentRequest(image: Self.image(2), concept: "cup"))
        _ = try await cache.segment(SegmentRequest(image: Self.image(1), concept: "mug"))
        _ = try await cache.segment(SegmentRequest(image: Self.image(1), concept: "cup", box: .whole))
        _ = try await cache.segment(SegmentRequest(image: Self.image(1), concept: "cup", points: [NormalizedPoint(x: 0.5, y: 0.5)]))
        #expect(await counter.calls == 5)
    }

    @Test func onlyTheMostRecentAnswersAreKept() async throws {
        let counter = CountingSegmenter(answer: Self.found)
        let cache = CachingSegmenter(counter, capacity: 2)
        for byte: UInt8 in [1, 2, 3] { _ = try await cache.segment(SegmentRequest(image: Self.image(byte), concept: "cup")) }
        _ = try await cache.segment(SegmentRequest(image: Self.image(3), concept: "cup"))
        #expect(await counter.calls == 3, "the latest is still there")
        _ = try await cache.segment(SegmentRequest(image: Self.image(1), concept: "cup"))
        #expect(await counter.calls == 4, "the oldest was let go")
    }

    @Test func aFailureIsNotRemembered() async throws {
        let counter = CountingSegmenter(answer: Self.found, failFirst: true)
        let cache = CachingSegmenter(counter)
        let ask = SegmentRequest(image: Self.image(1), concept: "cup")
        await #expect(throws: (any Error).self) { try await cache.segment(ask) }
        #expect(try await cache.segment(ask) == Self.found)
        #expect(await counter.calls == 2)
    }
}

private actor CountingSegmenter: Segmenter {
    nonisolated let modelID = "sam-test"
    private let answer: [Segment]
    private var failFirst: Bool
    private(set) var calls = 0

    init(answer: [Segment], failFirst: Bool = false) { self.answer = answer; self.failFirst = failFirst }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        calls += 1
        if failFirst { failFirst = false; throw CancellationError() }
        return answer
    }
}
