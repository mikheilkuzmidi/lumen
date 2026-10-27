import CryptoKit
import Foundation

/// Answers a segmentation it has already been asked, for the same picture and the same prompt, without asking again:
/// finding "cup" in the same photo twice (after an undo, or to update a mask) is one SAM call, not two. A repeat
/// reports no usage, so nothing is charged for it. The most recent `capacity` answers are kept, in memory only.
public actor CachingSegmenter: Segmenter {
    public nonisolated let modelID: String
    private let wrapped: any Segmenter
    private let capacity: Int
    private var answers: [String: [Segment]] = [:]
    private var order: [String] = []
    /// Asks answered from the cache, and asks passed on.
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(_ wrapped: any Segmenter, capacity: Int = 32) {
        self.wrapped = wrapped
        self.capacity = max(1, capacity)
        modelID = wrapped.modelID
    }

    public func segment(_ request: SegmentRequest) async throws -> [Segment] {
        let key = Self.key(request)
        if let answer = answers[key] {
            hits += 1
            order.removeAll { $0 == key }
            order.append(key)
            return answer
        }
        misses += 1
        let answer = try await wrapped.segment(request)
        answers[key] = answer
        order.append(key)
        if order.count > capacity { answers[order.removeFirst()] = nil }
        return answer
    }

    /// The picture's bytes and every part of the prompt.
    static func key(_ request: SegmentRequest) -> String {
        var hash = SHA256()
        hash.update(data: request.image.data)
        let prompt = [request.concept ?? "", request.box.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "",
                      request.points.map { "\($0.x),\($0.y)" }.joined(separator: ";")].joined(separator: "|")
        hash.update(data: Data(prompt.utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
