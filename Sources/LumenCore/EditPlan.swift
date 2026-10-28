import Foundation

/// A develop setting a step can change, with the range its value is held to.
public enum AdjustmentKey: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case temperature, tint, vibrance, saturation
    /// Warm (positive) or cool the highlights and the shadows on their own, as a colour grade does: golden light is
    /// warm highlights over shadows a little less warm.
    case highlightWarmth, shadowWarmth
    case clarity, dehaze, sharpness, noiseReduction

    /// Exposure in stops; sharpness and noise reduction from none to full; the rest as a signed percentage.
    public var range: ClosedRange<Double> {
        switch self {
        case .exposure: -5...5
        case .sharpness, .noiseReduction: 0...100
        default: -100...100
        }
    }

    /// Its name in words: "noise reduction", "highlight warmth".
    public var title: String {
        rawValue.reduce(into: "") { name, character in
            if character.isUppercase { name += " " + character.lowercased() } else { name.append(character) }
        }
    }
}

/// Find a region for later steps to work on.
public struct Selection: Codable, Equatable, Sendable {
    /// The name later steps use for it, such as "sky" or "coat".
    public var id: String
    /// What to find, in a few words: "the man's coat".
    public var concept: String?
    /// Where to look: the area the user drew, or one the planner chose.
    public var box: NormalizedRect?
    /// Points on the thing itself.
    public var points: [NormalizedPoint]
    /// Everything except what was found.
    public var invert: Bool
    /// Light falling across the photo, full at one point and gone at another: alone, the region is that ramp; with a
    /// concept, box or points, what is found fades along it.
    public var gradient: Gradient?
    /// The shadow what is found casts on the ground, its top landing at this point: a low sun's long shadow.
    public var shadowTip: NormalizedPoint?

    public init(id: String, concept: String? = nil, box: NormalizedRect? = nil, points: [NormalizedPoint] = [], invert: Bool = false,
                gradient: Gradient? = nil, shadowTip: NormalizedPoint? = nil) {
        self.id = id
        self.concept = concept
        self.box = box
        self.points = points
        self.invert = invert
        self.gradient = gradient
        self.shadowTip = shadowTip
    }

    private enum CodingKeys: String, CodingKey { case id, concept, box, points, invert, gradient, shadowTip }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        concept = try container.decodeIfPresent(String.self, forKey: .concept)
        box = try container.decodeIfPresent(NormalizedRect.self, forKey: .box)
        points = try container.decodeIfPresent([NormalizedPoint].self, forKey: .points) ?? []
        invert = try container.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        gradient = try container.decodeIfPresent(Gradient.self, forKey: .gradient)
        shadowTip = try container.decodeIfPresent(NormalizedPoint.self, forKey: .shadowTip)
    }
}

/// A ramp across the photo: full at `from`, none at `to` and beyond, eased in between.
public struct Gradient: Codable, Equatable, Sendable {
    public var from: NormalizedPoint
    public var to: NormalizedPoint

    public init(from: NormalizedPoint, to: NormalizedPoint) {
        self.from = from
        self.to = to
    }
}

/// Change develop settings, on the whole photo or inside a selected region.
public struct Adjustment: Codable, Equatable, Sendable {
    /// A region's id from an earlier select step; nil for the whole photo.
    public var region: String?
    public var values: [AdjustmentKey: Double]

    public init(region: String? = nil, values: [AdjustmentKey: Double]) {
        self.region = region
        self.values = values
    }

    private enum CodingKeys: String, CodingKey { case region, values }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        let entries = try container.decode([AdjustmentKey: Double?].self, forKey: .values)
        values = entries.compactMapValues { $0 }
    }
}

/// Redraw what is inside a region with Muse Image, as the prompt describes.
public struct Regeneration: Codable, Equatable, Sendable {
    public var region: String
    public var prompt: String

    public init(region: String, prompt: String) {
        self.region = region
        self.prompt = prompt
    }
}

/// Take a region out and fill it from its surroundings.
public struct Removal: Codable, Equatable, Sendable {
    public var region: String

    public init(region: String) { self.region = region }
}

/// Keep only this part of the photo.
public struct Crop: Codable, Equatable, Sendable {
    public var rect: NormalizedRect

    public init(rect: NormalizedRect) { self.rect = rect }
}

/// Take an earlier layer off the photo.
public struct Revert: Codable, Equatable, Sendable {
    public var layer: String

    public init(layer: String) { self.layer = layer }
}

/// The edit is done, and why.
public struct Finish: Codable, Equatable, Sendable {
    public var reason: String

    public init(reason: String) { self.reason = reason }
}

/// One thing the agent does. In JSON it is a flat object with a `type` ("select", "adjust", "regenerate",
/// "remove", "crop", "revert" or "finish") beside that step's own fields; this is the contract every planner answers in.
public enum EditStep: Codable, Equatable, Sendable {
    case select(Selection)
    case adjust(Adjustment)
    case regenerate(Regeneration)
    case remove(Removal)
    case crop(Crop)
    case revert(Revert)
    case finish(Finish)

    public var type: String {
        switch self {
        case .select: "select"
        case .adjust: "adjust"
        case .regenerate: "regenerate"
        case .remove: "remove"
        case .crop: "crop"
        case .revert: "revert"
        case .finish: "finish"
        }
    }

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "select": self = .select(try Selection(from: decoder))
        case "adjust": self = .adjust(try Adjustment(from: decoder))
        case "regenerate": self = .regenerate(try Regeneration(from: decoder))
        case "remove": self = .remove(try Removal(from: decoder))
        case "crop": self = .crop(try Crop(from: decoder))
        case "revert": self = .revert(try Revert(from: decoder))
        case "finish": self = .finish(try Finish(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown step type “\(type)”.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(type, forKey: .type)
        switch self {
        case .select(let step): try step.encode(to: encoder)
        case .adjust(let step): try step.encode(to: encoder)
        case .regenerate(let step): try step.encode(to: encoder)
        case .remove(let step): try step.encode(to: encoder)
        case .crop(let step): try step.encode(to: encoder)
        case .revert(let step): try step.encode(to: encoder)
        case .finish(let step): try step.encode(to: encoder)
        }
    }
}

/// What a planner proposes for an instruction: a one-line summary and the steps, in order.
public struct EditPlan: Codable, Equatable, Sendable {
    public var summary: String
    public var steps: [EditStep]

    public init(summary: String, steps: [EditStep]) {
        self.summary = summary
        self.steps = steps
    }
}

extension EditPlan {
    /// The JSON Schema of a plan, in the strict subset structured output accepts (every field present,
    /// optional ones nullable), for planners to pass as their response format.
    public static func jsonSchema() -> Data { PlanSchema.plan() }
}

/// A planner's plan made safe to run: values held to their ranges, coordinates kept on the photo, steps that use a
/// region no step selected dropped, and `finish` only at the end. `notes` says, in words, what was changed.
public struct CheckedPlan: Equatable, Sendable {
    public var plan: EditPlan
    public var notes: [String]

    public init(plan: EditPlan, notes: [String]) {
        self.plan = plan
        self.notes = notes
    }
}

extension EditPlan {
    /// `knownRegions` are the ids selected by earlier plans of the same edit.
    public func checked(knownRegions: Set<String> = []) -> CheckedPlan {
        checked(knownRegions: knownRegions, knownLayers: [])
    }

    /// Keeps references to regions and applied layers from earlier plans of this edit.
    public func checked(knownRegions: Set<String>, knownLayers: Set<String>) -> CheckedPlan {
        var check = PlanCheck(knownRegions: knownRegions, knownLayers: knownLayers)
        return check.check(self)
    }
}
