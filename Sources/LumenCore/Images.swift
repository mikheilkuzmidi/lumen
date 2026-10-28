import Foundation

/// An image as files carry it: its encoded bytes and its size.
public struct EncodedImage: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        case jpeg, png
        public var mimeType: String { self == .jpeg ? "image/jpeg" : "image/png" }
    }

    public var data: Data
    public var format: Format
    public var size: PixelSize

    public init(data: Data, format: Format, size: PixelSize) {
        self.data = data
        self.format = format
        self.size = size
    }

    /// A `data:` URL, as image inputs to the Meta Model API are sent.
    public var dataURL: String { "data:\(format.mimeType);base64,\(data.base64EncodedString())" }
}

/// Where an edit applies: one coverage value per pixel, 0 (untouched) to 255 (fully), rows from the top.
public struct MaskData: Codable, Equatable, Sendable {
    public var size: PixelSize
    public var coverage: [UInt8]
    /// A mask of something in the photo, which a host fits to the photo's own edges. A gradient or a cast shadow,
    /// drawn as it should be, is used as it is: fitted to edges a shadow on even ground doesn't have, it spreads thin.
    public var followsPhoto: Bool

    public init(size: PixelSize, coverage: [UInt8], followsPhoto: Bool = true) {
        precondition(coverage.count == size.width * size.height, "one coverage value per pixel")
        self.size = size
        self.coverage = coverage
        self.followsPhoto = followsPhoto
    }

    private enum CodingKeys: String, CodingKey { case size, coverage, followsPhoto }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decode(PixelSize.self, forKey: .size)
        coverage = try container.decode([UInt8].self, forKey: .coverage)
        followsPhoto = try container.decodeIfPresent(Bool.self, forKey: .followsPhoto) ?? true
    }

    /// Every pixel at `value`.
    public init(size: PixelSize, filledWith value: UInt8) {
        self.init(size: size, coverage: [UInt8](repeating: value, count: size.width * size.height))
    }

    public subscript(x: Int, y: Int) -> UInt8 { coverage[y * size.width + x] }

    /// The share of the photo the mask covers, 0...1.
    public var area: Double {
        guard !coverage.isEmpty else { return 0 }
        return Double(coverage.reduce(0) { $0 + Int($1) }) / (255 * Double(coverage.count))
    }
}
