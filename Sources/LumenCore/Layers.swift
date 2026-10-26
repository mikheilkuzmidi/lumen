import Foundation

/// A mask or an image kept beside the layers that use it.
public struct AssetID: Codable, Hashable, Sendable {
    public var rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum Asset: Codable, Equatable, Sendable {
    case mask(MaskData)
    case image(EncodedImage)
}

/// Where the masks and generated images of an edit live.
public actor AssetStore {
    private var assets: [AssetID: Asset] = [:]

    public init() {}

    @discardableResult
    public func put(_ asset: Asset) -> AssetID {
        let id = AssetID()
        assets[id] = asset
        return id
    }

    public func get(_ id: AssetID) -> Asset? { assets[id] }

    public func remove(_ id: AssetID) { assets[id] = nil }
}

/// One non-destructive change on top of the photo. Turning it off or removing it leaves the photo as it was.
public struct Layer: Codable, Equatable, Identifiable, Sendable {
    public enum Content: Codable, Equatable, Sendable {
        /// Develop settings, inside a mask or (nil) on the whole photo.
        case adjustment(values: [AdjustmentKey: Double], mask: AssetID?)
        /// Generated pixels placed over `rect`, shown through the mask.
        case patch(image: AssetID, mask: AssetID, rect: NormalizedRect)
        case crop(NormalizedRect)
    }

    public var id: UUID
    /// What the step did, in words: "Sky: exposure −0.4".
    public var label: String
    public var content: Content
    public var isEnabled: Bool
    /// 0...1.
    public var opacity: Double

    public init(id: UUID = UUID(), label: String, content: Content, isEnabled: Bool = true, opacity: Double = 1) {
        self.id = id
        self.label = label
        self.content = content
        self.isEnabled = isEnabled
        self.opacity = opacity
    }
}

/// The layers of an edit, bottom first.
public struct LayerStack: Codable, Equatable, Sendable {
    public var layers: [Layer]

    public init(layers: [Layer] = []) { self.layers = layers }
}
