import Foundation

/// A region an earlier step selected, as a planner is told about it.
public struct RegionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var concept: String?
    public var box: NormalizedRect
    /// The share of the photo it covers, 0...1.
    public var area: Double

    public init(id: String, concept: String?, box: NormalizedRect, area: Double) {
        self.id = id
        self.concept = concept
        self.box = box
        self.area = area
    }
}

/// An applied layer the planner can refer to or revert.
public struct LayerInfo: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// The step that made the layer: adjust, regenerate, remove or crop.
    public var kind: String
    public var region: String?

    public init(id: String, label: String, kind: String, region: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.region = region
    }
}

public struct PlanRequest: Sendable {
    public var instruction: String
    /// The photo as it looks now.
    public var image: EncodedImage
    /// Where the user asked the agent to look, if they drew an area.
    public var area: NormalizedRect?
    public var regions: [RegionInfo]
    /// What has been done so far, step by step, in words.
    public var done: [String]
    /// Applied layers, oldest first.
    public var layers: [LayerInfo]
    /// Earlier instructions for this photo, oldest first.
    public var history: [String]

    public init(instruction: String, image: EncodedImage, area: NormalizedRect? = nil, regions: [RegionInfo] = [],
                done: [String] = [], layers: [LayerInfo] = [], history: [String] = []) {
        self.instruction = instruction
        self.image = image
        self.area = area
        self.regions = regions
        self.done = done
        self.layers = layers
        self.history = history
    }
}

public struct CritiqueRequest: Sendable {
    public var instruction: String
    public var before: EncodedImage
    public var after: EncodedImage
    public var regions: [RegionInfo]
    public var done: [String]
    public var layers: [LayerInfo]

    public init(instruction: String, before: EncodedImage, after: EncodedImage, regions: [RegionInfo] = [],
                done: [String] = [], layers: [LayerInfo] = []) {
        self.instruction = instruction
        self.before = before
        self.after = after
        self.regions = regions
        self.done = done
        self.layers = layers
    }
}

/// A planner's look at its own result.
public struct Critique: Codable, Equatable, Sendable {
    /// The result does what was asked.
    public var satisfied: Bool
    public var notes: String
    /// What to do next when it doesn't.
    public var steps: [EditStep]

    public init(satisfied: Bool, notes: String, steps: [EditStep] = []) {
        self.satisfied = satisfied
        self.notes = notes
        self.steps = steps
    }
}

extension Critique {
    /// The JSON Schema of a critique, in the same strict subset as `EditPlan.jsonSchema()`.
    public static func jsonSchema() -> Data { PlanSchema.critique() }
}

/// Turns an instruction and the photo into steps, and judges the result.
public protocol Planner: Sendable {
    var modelID: String { get }
    func plan(_ request: PlanRequest) async throws -> EditPlan
    func critique(_ request: CritiqueRequest) async throws -> Critique
}

public struct SegmentRequest: Sendable {
    public var image: EncodedImage
    public var concept: String?
    public var box: NormalizedRect?
    public var points: [NormalizedPoint]

    public init(image: EncodedImage, concept: String? = nil, box: NormalizedRect? = nil, points: [NormalizedPoint] = []) {
        self.image = image
        self.concept = concept
        self.box = box
        self.points = points
    }
}

/// One thing found in the photo.
public struct Segment: Equatable, Sendable {
    public var label: String
    public var box: NormalizedRect
    /// The photo's size.
    public var mask: MaskData
    public var score: Double?

    public init(label: String, box: NormalizedRect, mask: MaskData, score: Double? = nil) {
        self.label = label
        self.box = box
        self.mask = mask
        self.score = score
    }
}

/// Finds things in a photo by words, a box or points.
public protocol Segmenter: Sendable {
    var modelID: String { get }
    func segment(_ request: SegmentRequest) async throws -> [Segment]
}

public struct GenerateRequest: Sendable {
    /// The part of the photo around the region.
    public var image: EncodedImage
    /// What may change, the same size as `image`.
    public var mask: MaskData
    public var prompt: String

    public init(image: EncodedImage, mask: MaskData, prompt: String) {
        self.image = image
        self.mask = mask
        self.prompt = prompt
    }
}

/// Redraws part of a photo as a prompt describes.
public protocol Generator: Sendable {
    var modelID: String { get }
    func generate(_ request: GenerateRequest) async throws -> EncodedImage
}

/// What the agent edits: a photo with layers on it. Lumen's own renderer is one; an editor can be another.
public protocol EditHost: Sendable {
    /// The original photo's size.
    func size() async -> PixelSize
    /// The photo as its layers make it now, at most `maxLongEdge` pixels on its long edge.
    func render(maxLongEdge: Int) async throws -> EncodedImage
    /// Part of the photo as its layers make it now, at its full resolution up to `maxLongEdge`.
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage
    /// Puts a layer on top; its masks and images are in `assets`.
    func apply(_ layer: Layer, assets: AssetStore) async throws
    /// Takes a layer off again.
    func remove(_ layer: Layer.ID) async throws
}
