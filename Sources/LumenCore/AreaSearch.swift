import Foundation

/// Finds a named thing inside an area a person marked, the way the agent selects within one: by name first, keeping
/// only what lies mostly inside the area; when nothing by that name is there, the area itself becomes the
/// segmenter's object prompt, as a box drawn around a thing selects it.
public struct AreaSearch: Sendable {
    public enum Method: String, Sendable {
        /// Found by name inside the area.
        case name
        /// Nothing by that name was inside; the area was the object prompt.
        case area
    }

    public struct Found: Equatable, Sendable {
        /// Everything found, as one mask at the image's size.
        public var mask: MaskData
        /// How many separate things it covers.
        public var count: Int
        public var method: Method
    }

    public let segmenter: any Segmenter
    /// The share of a thing's coverage that must lie inside the area for it to count as there.
    public var inside: Double

    public init(segmenter: any Segmenter, inside: Double = 0.5) {
        self.segmenter = segmenter
        self.inside = inside
    }

    /// Looks for `concept` in `image`, only inside `area` when there is one. Returns nil when nothing is found.
    public func find(_ concept: String, in image: EncodedImage, area: NormalizedRect?) async throws -> Found? {
        let named = try await segmenter.segment(SegmentRequest(image: image, concept: concept, box: area))
        // Most segmenters already keep to the box; this holds for any of them.
        let kept = area.map { area in named.filter { $0.mask.share(inside: area) >= inside } } ?? named
        if let found = Self.found(kept, method: .name) { return found }
        guard let area else { return nil }
        let framed = try await segmenter.segment(SegmentRequest(image: image, box: area))
        return Self.found(framed, method: .area)
    }

    private static func found(_ segments: [Segment], method: Method) -> Found? {
        let masks = segments.map(\.mask).filter { $0.area > 0 }
        guard let first = masks.first else { return nil }
        return Found(mask: masks.dropFirst().reduce(first) { $0.union($1) }, count: masks.count, method: method)
    }
}
