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

    public init(size: PixelSize, coverage: [UInt8]) {
        precondition(coverage.count == size.width * size.height, "one coverage value per pixel")
        self.size = size
        self.coverage = coverage
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
