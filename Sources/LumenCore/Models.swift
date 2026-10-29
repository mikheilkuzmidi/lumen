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
    /// Earlier instructions for this photo, oldest first, so "that" and "undo" can be read against them.
    public var history: [String]
    /// Each region redrawn in this run, close up, before and after: a smeared wheel is a few pixels of the whole photo.
    public var closeUps: [CloseUp]
    /// The colour of each region changed in this run, and of the rest of the photo, before and after: a change too
    /// slight to see, or a colour short of the one asked for, in numbers.
    public var measurements: [RegionChange]

    public init(instruction: String, before: EncodedImage, after: EncodedImage, regions: [RegionInfo] = [],
                done: [String] = [], layers: [LayerInfo] = [], history: [String] = [], closeUps: [CloseUp] = [],
                measurements: [RegionChange] = []) {
        self.instruction = instruction
        self.before = before
        self.after = after
        self.regions = regions
        self.done = done
        self.layers = layers
        self.history = history
        self.closeUps = closeUps
        self.measurements = measurements
    }
}

/// The colour of part of a photo in CIELAB, the way a person sees it.
public struct ColourMeasurement: Equatable, Sendable {
    /// 0 black to 100 white.
    public var lightness: Double
    /// Green (negative) to red (positive).
    public var a: Double
    /// Blue (negative) to yellow (positive).
    public var b: Double
    /// The lightness of the brightest and the darkest tenth: a night city's lights, which its middle colour (the
    /// black sky) hides.
    public var brightest: Double?
    public var darkest: Double?
    /// The share of the part in each colour family covering at least 3% of it ("red": 0.06): a red trim left on a
    /// jacket made blue, which its middle colour hides.
    public var families: [String: Double]?

    public init(lightness: Double, a: Double, b: Double, brightest: Double? = nil, darkest: Double? = nil,
                families: [String: Double]? = nil) {
        self.lightness = lightness
        self.a = a
        self.b = b
        self.brightest = brightest
        self.darkest = darkest
        self.families = families
    }

    /// The colour's family, as a selection names colours: "dark teal" is teal, "charcoal" black, "light grey" grey.
    public var family: String {
        let name = self.name
        if name == "charcoal" { return "black" }
        if name.hasSuffix("grey") { return "grey" }
        return String(name.split(separator: " ").last ?? Substring(name))
    }

    /// Whether the colour is in `family` by hue, whatever its lightness: an orange poppy in shade names as brown.
    public func isIn(_ family: String) -> Bool {
        if self.family == family { return true }
        guard chroma >= 15 else { return false }
        let hues: [String: [ClosedRange<Double>]] = [
            "red": [20...58], "orange": [50...82], "yellow": [78...110], "green": [105...172], "teal": [168...238],
            "blue": [232...312], "purple": [305...348], "pink": [340...360, 0...28], "brown": [25...110],
        ]
        return hues[family]?.contains { $0.contains(hue) } ?? false
    }

    /// 0 for grey; about 30 and above is vivid.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// The hue angle in degrees: red near 40, yellow near 100, green near 140, teal near 200, blue near 290.
    public var hue: Double {
        let angle = atan2(b, a) * 180 / .pi
        return angle < 0 ? angle + 360 : angle
    }

    /// How far apart two colours look (CIE76): under about 3 is hard to see.
    public func difference(to other: ColourMeasurement) -> Double {
        let l = lightness - other.lightness, a = self.a - other.a, b = self.b - other.b
        return (l * l + a * a + b * b).squareRoot()
    }

    /// The colour in a few words, such as "black", "charcoal", "dark teal" or "muted blue".
    public var name: String {
        if chroma < 10 {
            // A black cup in a lit room reads about 10; one that reads 20 looks charcoal, not black.
            switch lightness {
            case ..<15: return "black"
            case ..<30: return "charcoal"
            case ..<45: return "dark grey"
            case ..<70: return "grey"
            case ..<88: return "light grey"
            default: return "white"
            }
        }
        let hue = self.hue
        let family: String
        switch hue {
        case 25..<55: family = "red"
        case 55..<80: family = "orange"
        case 80..<108: family = "yellow"
        case 108..<170: family = "green"
        case 170..<235: family = "teal"
        case 235..<310: family = "blue"
        case 310..<345: family = "purple"
        default: family = "pink"
        }
        if (25..<108).contains(hue), lightness < 50, chroma < 45 { return lightness < 25 ? "dark brown" : "brown" }
        let shade = lightness < 35 ? "dark " : lightness > 78 ? "light " : ""
        return (chroma < 20 ? "muted " : "") + shade + family
    }
}

/// Part of the photo measured at the start of an instruction and after its edit.
public struct RegionChange: Equatable, Sendable {
    /// A region's id, or "rest of the photo" or "photo".
    public var region: String
    public var before: ColourMeasurement
    public var after: ColourMeasurement

    public init(region: String, before: ColourMeasurement, after: ColourMeasurement) {
        self.region = region
        self.before = before
        self.after = after
    }

    /// How far the colour moved, in CIE76: under about 3 is hard to see.
    public var change: Double { before.difference(to: after) }
}

/// A redrawn region seen close up, before this run's redraw and as it is now.
public struct CloseUp: Equatable, Sendable {
    public var region: String
    public var before: EncodedImage
    public var after: EncodedImage
    /// Where the close-up lost most of its fine detail, worst first: a likely smear.
    public var lostDetail: [LostDetail]

    public init(region: String, before: EncodedImage, after: EncodedImage, lostDetail: [LostDetail] = []) {
        self.region = region
        self.before = before
        self.after = after
        self.lostDetail = lostDetail
    }
}

/// A place in a close-up that kept little of the fine detail it had.
public struct LostDetail: Equatable, Sendable {
    /// Where, as a rectangle of the close-up.
    public var rect: NormalizedRect
    /// The least share of its fine detail any part of it kept, 0...1.
    public var kept: Double

    public init(rect: NormalizedRect, kept: Double) {
        self.rect = rect
        self.kept = kept
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
    /// `mask`, over `region` at its own size, held to the photo's own edges there, as the photo is now.
    func fitted(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData
    /// `mask`, over `region` at its own size, grown a little over neighbouring pixels of the colour it covers, as the
    /// photo is now: the rim or shaded part of a thing its mask stopped short of.
    func extended(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData
    /// The colour most of `image` has, a render of the photo as it is framed now, where `mask` (over the whole photo)
    /// covers it; all of it when `mask` is nil. Nil when nothing is covered.
    func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement?
    /// Where `after`, a close-up of the same place as `before`, lost most of the fine detail `before` had.
    func lostDetail(before: EncodedImage, after: EncodedImage) async throws -> [LostDetail]
    /// `image`, a crop around a person, with the person in `mask` (the crop's size) reshaped: their outline wider by
    /// `shoulders` at the shoulders and by `waist` at the waist, as shares (negative narrows), and what `keep` covers
    /// (something they hold) left where it is. Nil when the host can't, or finds no body in the mask.
    func reshaped(_ image: EncodedImage, mask: MaskData, keep: MaskData?, shoulders: Double, waist: Double) async throws -> Reshaped?
    /// `generated`, a redraw of the crop `original`, with its colour cast under `mask` moved back to the original's,
    /// keeping its own lightness, and nothing changed outside the mask. Nil when the host can't.
    func toneMatched(_ generated: EncodedImage, to original: EncodedImage, under mask: MaskData) async throws -> EncodedImage?
}

/// A crop with a person reshaped, and where its pixels changed.
public struct Reshaped: Equatable, Sendable {
    public var image: EncodedImage
    /// The crop's size: covered where the reshape moved pixels.
    public var changed: MaskData

    public init(image: EncodedImage, changed: MaskData) {
        self.image = image
        self.changed = changed
    }
}

public extension EditHost {
    /// A host that can't look at its pixels uses the mask as it is.
    func fitted(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData { mask }
    func extended(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData { mask }
    /// A host that can't look at its pixels measures nothing, and the critic judges by eye alone.
    func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? { nil }
    /// A host that can't look at its pixels finds no lost detail, and the critic looks at the close-ups alone.
    func lostDetail(before: EncodedImage, after: EncodedImage) async throws -> [LostDetail] { [] }
    /// A host that can't move its pixels has a body reshaped by the image model instead.
    func reshaped(_ image: EncodedImage, mask: MaskData, keep: MaskData?, shoulders: Double, waist: Double) async throws -> Reshaped? { nil }
    /// A host that can't change its pixels has a drifted face drawn again instead.
    func toneMatched(_ generated: EncodedImage, to original: EncodedImage, under mask: MaskData) async throws -> EncodedImage? { nil }
}
