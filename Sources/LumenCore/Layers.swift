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
        /// Generated pixels placed over `rect`, shown through the mask. The image and the mask both cover
        /// exactly `rect` (the mask is usually at the image's size).
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
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []

    private struct Entry: Codable, Equatable, Sendable {
        var layers: [Layer]
        var label: String
    }

    public init(layers: [Layer] = []) { self.layers = layers }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoLabel: String? { undoEntries.last?.label }
    public var redoLabel: String? { redoEntries.last?.label }

    public func layer(id: Layer.ID) -> Layer? { layers.first { $0.id == id } }

    public mutating func append(_ layer: Layer) {
        record("Add \(layer.label)")
        layers.append(layer)
    }

    public mutating func remove(id: Layer.ID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        record("Remove \(layers[index].label)")
        layers.remove(at: index)
    }

    public mutating func setEnabled(_ enabled: Bool, for id: Layer.ID) {
        guard let index = layers.firstIndex(where: { $0.id == id }), layers[index].isEnabled != enabled else { return }
        record("\(enabled ? "Enable" : "Disable") \(layers[index].label)")
        layers[index].isEnabled = enabled
    }

    public mutating func setOpacity(_ opacity: Double, for id: Layer.ID) {
        guard !opacity.isNaN, let index = layers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(opacity, 0), 1)
        guard layers[index].opacity != clamped else { return }
        record("Change opacity of \(layers[index].label)")
        layers[index].opacity = clamped
    }

    /// Restores the stack before the last change and returns that change's label.
    @discardableResult
    public mutating func undo() -> String? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(Entry(layers: layers, label: entry.label))
        layers = entry.layers
        return entry.label
    }

    /// Restores the next undone change and returns its label.
    @discardableResult
    public mutating func redo() -> String? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(Entry(layers: layers, label: entry.label))
        layers = entry.layers
        return entry.label
    }

    private mutating func record(_ label: String) {
        undoEntries.append(Entry(layers: layers, label: label))
        redoEntries.removeAll()
    }

    private enum CodingKeys: String, CodingKey { case layers, undoEntries, redoEntries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layers = try container.decode([Layer].self, forKey: .layers)
        undoEntries = try container.decodeIfPresent([Entry].self, forKey: .undoEntries) ?? []
        redoEntries = try container.decodeIfPresent([Entry].self, forKey: .redoEntries) ?? []
    }
}
