import Foundation

/// Finds a named thing inside an area a person marked, the way the agent selects within one: by name first, keeping
/// only what lies mostly inside the area; when nothing by that name is there, the area itself becomes the
/// segmenter's object prompt, as a box drawn around a thing selects it, and when that comes back as a few specks,
/// the area itself is the selection.
public struct AreaSearch: Sendable {
    public enum Method: String, Sendable {
        /// Found by name inside the area.
        case name
        /// Nothing by that name was inside; the area was the object prompt.
        case area
        /// Nothing by that name was inside, and what the area framed was too thin to be a selection (a few specks): the
        /// area itself.
        case whole
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
    /// The least share of the area what it frames must cover to be a selection, rather than the area itself.
    public var solid: Double

    public init(segmenter: any Segmenter, inside: Double = 0.5, solid: Double = 0.1) {
        self.segmenter = segmenter
        self.inside = inside
        self.solid = solid
    }

    /// Looks for `concept` in `image`, only inside `area` when there is one. Returns nil when nothing is found.
    public func find(_ concept: String, in image: EncodedImage, area: NormalizedRect?) async throws -> Found? {
        let named = try await segmenter.segment(SegmentRequest(image: image, concept: concept, box: area))
        // Most segmenters already keep to the box; this holds for any of them.
        let kept = area.map { area in named.filter { $0.mask.share(inside: area) >= inside } } ?? named
        if let found = Self.found(kept, method: .name) { return found }
        guard let area else { return nil }
        let framed = try await segmenter.segment(SegmentRequest(image: image, box: area))
        guard let found = Self.found(framed, method: .area) else { return nil }
        if Self.share(of: found.mask, in: area) >= solid { return found }
        return Found(mask: Self.filled(area, size: found.mask.size), count: 1, method: .whole)
    }

    /// How much of `area` the mask covers, 0...1.
    static func share(of mask: MaskData, in area: NormalizedRect) -> Double {
        let w = mask.size.width, h = mask.size.height
        let x0 = max(0, Int((area.x * Double(w)).rounded(.down))), x1 = min(w, Int(((area.x + area.width) * Double(w)).rounded(.up)))
        let y0 = max(0, Int((area.y * Double(h)).rounded(.down))), y1 = min(h, Int(((area.y + area.height) * Double(h)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var covered = 0.0
        for y in y0..<y1 { for x in x0..<x1 { covered += Double(mask[x, y]) / 255 } }
        return covered / Double((x1 - x0) * (y1 - y0))
    }

    /// The area as a mask: full inside, nothing outside.
    static func filled(_ area: NormalizedRect, size: PixelSize) -> MaskData {
        let w = size.width, h = size.height
        let x0 = max(0, Int((area.x * Double(w)).rounded())), x1 = min(w, Int(((area.x + area.width) * Double(w)).rounded()))
        let y0 = max(0, Int((area.y * Double(h)).rounded())), y1 = min(h, Int(((area.y + area.height) * Double(h)).rounded()))
        var coverage = [UInt8](repeating: 0, count: w * h)
        if x1 > x0, y1 > y0 { for y in y0..<y1 { for x in x0..<x1 { coverage[y * w + x] = 255 } } }
        return MaskData(size: size, coverage: coverage)
    }

    private static func found(_ segments: [Segment], method: Method) -> Found? {
        let masks = segments.map(\.mask).filter { $0.area > 0 }
        guard let first = masks.first else { return nil }
        return Found(mask: masks.dropFirst().reduce(first) { $0.union($1) }, count: masks.count, method: method)
    }
}
