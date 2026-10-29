import Foundation

/// A fun edit of a person, redrawn only where they are: their face, their head or their body, never the whole photo.
/// Each has a prompt tuned for Muse Image and, where it changes a shape, how much it may.
public struct PersonStyle: Equatable, Sendable {
    public enum Part: String, Sendable {
        case face, head, body

        /// What the segmentation model is asked to find for it.
        public var concept: String {
            switch self {
            case .face: "face"
            case .head: "head"
            case .body: "person"
            }
        }
    }

    public var id: String
    public var title: String
    public var part: Part
    /// The change, said to Muse Image.
    public var change: String
    /// Reshaping a face or a body, or ageing one, is only for adults.
    public var adultsOnly: Bool
    /// How much the part's outline may change; nil when its outline isn't the point.
    public var limits: ShapeLimits?
    /// The effect that goes with it, applied after.
    public var effect: String?
    /// A body's outline moved by exactly this much, by a warp, where the host can: the image model changes a body's
    /// shape by a percent or two, or not at all.
    public var reshape: Reshape?
    /// Whether the image model redraws the part as `change` says; a style that only reshapes asks it only where the
    /// host can't warp.
    public var redraws: Bool

    public struct Reshape: Equatable, Sendable {
        public var shoulders: Double
        public var waist: Double

        public init(shoulders: Double, waist: Double) {
            self.shoulders = shoulders
            self.waist = waist
        }
    }

    public init(id: String, title: String, part: Part, change: String, adultsOnly: Bool, limits: ShapeLimits? = nil,
                effect: String? = nil, reshape: Reshape? = nil, redraws: Bool = true) {
        self.id = id
        self.title = title
        self.part = part
        self.change = change
        self.adultsOnly = adultsOnly
        self.limits = limits
        self.effect = effect
        self.reshape = reshape
        self.redraws = redraws
    }

    public static func named(_ id: String) -> PersonStyle? { all.first { $0.id == id } }

    public static let all: [PersonStyle] = [
        PersonStyle(id: "chad", title: "Chad face", part: .face,
                    change: "Give this person a chiselled \"Chad\" look: a visibly stronger, squarer jawline and chin, "
                        + "defined cheekbones, a focused, confident gaze and light stubble.",
                    adultsOnly: true, limits: ShapeLimits(least: 0, most: 0.2, measures: "jaw")),
        PersonStyle(id: "gigachad", title: "Gigachad", part: .face,
                    change: "Turn this person into the \"Gigachad\" meme: a very strong, wide, square jaw and chin, sharply "
                        + "defined cheekbones and brow ridge, an intense stare and a short dark beard shadow.",
                    adultsOnly: true, limits: ShapeLimits(least: 0, most: 0.3, measures: "jaw"), effect: "monoDrama"),
        PersonStyle(id: "hollywood", title: "Hollywood glow-up", part: .face,
                    change: "Give this person a red-carpet polish: even, healthy skin that keeps its real texture and pores, "
                        + "groomed brows, bright eyes and soft, natural contouring.",
                    adultsOnly: true),
        PersonStyle(id: "beard", title: "Full beard", part: .face,
                    change: "Give this person a full, well-groomed beard and moustache in the colour of their own hair.",
                    adultsOnly: true),
        PersonStyle(id: "older", title: "30 years older", part: .head,
                    change: "Show this person about 30 years older: natural wrinkles, softer skin, thinner greying hair, "
                        + "the same face grown older.",
                    adultsOnly: true),
        PersonStyle(id: "smile", title: "Big smile", part: .face,
                    change: "Change this person's expression to a natural, wide smile that reaches the eyes, showing the teeth.",
                    adultsOnly: false),
        PersonStyle(id: "shades", title: "Aviator shades", part: .face,
                    change: "Put a pair of classic aviator sunglasses on this person, sitting naturally on the nose, "
                        + "with real reflections of the scene in the lenses.",
                    adultsOnly: false),
        PersonStyle(id: "zombie", title: "Zombie make-up", part: .face,
                    change: "Give this person Halloween zombie make-up on the same face: pale grey-green skin, dark sunken "
                        + "eyes and painted scars.",
                    adultsOnly: false),
        PersonStyle(id: "platinum", title: "Platinum blonde", part: .head,
                    change: "Dye this person's hair a bright platinum blonde, a solid, fully dyed colour from the roots to "
                        + "the tips, keeping its cut, length and texture.",
                    adultsOnly: false),
        PersonStyle(id: "athletic", title: "Athletic build", part: .body,
                    change: "Make this person clearly more athletic, as after a few months of training: shoulders about 10% "
                        + "broader and waist about 10% narrower for a visible V-shaped torso, a firmer chest and more "
                        + "defined arms, their clothes fitting the new shape.",
                    adultsOnly: true, limits: ShapeLimits(least: 0.02, most: 0.15, measures: "shoulders and waist"),
                    reshape: Reshape(shoulders: 0.1, waist: -0.1), redraws: false),
        PersonStyle(id: "muscular", title: "Gym-built", part: .body,
                    change: "Show this same person after a year of serious gym training: noticeably broader shoulders, a "
                        + "bigger chest and thicker, defined arms, their clothes stretched over the new muscles.",
                    adultsOnly: true, limits: ShapeLimits(least: 0.03, most: 0.2, measures: "shoulders and waist")),
    ]

    /// What Muse Image is asked: the change, which part of whom and where, what stays, and how to fill where the
    /// outline moves in. Said outright, with amounts: asked for "slightly broader shoulders, not a bodybuilder", it
    /// changed nothing.
    public func prompt(person: String, place: String, firmer: Firmness = .asked) -> String {
        let part = switch self.part {
        case .face: "face"
        case .head: "head and hair"
        case .body: "body"
        }
        var text = change
        switch firmer {
        case .asked: break
        case .subtler: text += " Make the change subtler, about half as much: it went too far."
        case .stronger: text += " Make the change clearly visible: it was too slight to see."
        case .sameTone: text += " Keep the skin exactly the photo's own tone, light and colour cast: the last try came out a different tone, which shows as a seam."
        }
        let stays = self.part == .body
            ? "Keep their face, pose and clothes and the background the same."
            : "Keep the same person, clearly recognisable, with exactly the photo's skin tone, colours and light."
        return "Edit this photo. \(text) Change only the \(part) of the \(person) \(place) of this picture; keep everything "
            + "else exactly as it is. \(stays) Where the outline moves in, continue the background behind it. Photorealistic."
    }

    public enum Firmness: Sendable { case asked, subtler, stronger, sameTone }

    /// Whether the part keeps the photo's own colour: all but those that recolour it (make-up, dyed or greying hair).
    public var keepsTone: Bool { !["zombie", "platinum", "older"].contains(id) }
}

/// How much a style may change the outline it measures, as a share of its width: at least `least` to be seen, at most
/// `most` to stay believable.
public struct ShapeLimits: Equatable, Sendable {
    public var least: Double
    public var most: Double
    /// What is measured, in words.
    public var measures: String

    public init(least: Double, most: Double, measures: String) {
        self.least = least
        self.most = most
        self.measures = measures
    }
}

/// A grade that goes with a style, or on its own: tone and colour settings over the whole photo, the person or
/// everything behind them.
public struct StyleEffect: Equatable, Sendable {
    public enum Target: String, Sendable { case photo, person, background }

    public struct Part: Equatable, Sendable {
        public var target: Target
        public var values: [AdjustmentKey: Double]
    }

    public var id: String
    public var title: String
    public var parts: [Part]

    /// Whether it needs a person to work on.
    public var needsPerson: Bool { parts.contains { $0.target != .photo } }

    public static func named(_ id: String) -> StyleEffect? { all.first { $0.id == id } }

    public static let all: [StyleEffect] = [
        StyleEffect(id: "monoDrama", title: "Dramatic black and white", parts: [
            Part(target: .photo, values: [.saturation: -100, .contrast: 45, .clarity: 35, .blacks: -20, .highlights: -20]),
        ]),
        StyleEffect(id: "mainCharacter", title: "Main character", parts: [
            Part(target: .background, values: [.exposure: -0.5, .saturation: -20]),
            Part(target: .person, values: [.exposure: 0.15]),
            Part(target: .photo, values: [.highlightWarmth: 15, .shadowWarmth: -15]),
        ]),
        StyleEffect(id: "vintage", title: "Vintage film", parts: [
            Part(target: .photo, values: [.contrast: -15, .blacks: 20, .saturation: -25, .highlightWarmth: 12, .highlights: -15]),
        ]),
        StyleEffect(id: "neonNight", title: "Neon night", parts: [
            Part(target: .photo, values: [.tint: 25, .temperature: -20, .contrast: 20, .vibrance: 30, .shadows: -15]),
        ]),
    ]
}

/// Restyle a selected person: one of `PersonStyle.all`, one of `StyleEffect.all`, or both. A style needs the region of
/// the person; an effect on the photo alone needs none.
public struct StyleStep: Codable, Equatable, Sendable {
    public var region: String?
    public var style: String?
    public var effect: String?

    public init(region: String? = nil, style: String? = nil, effect: String? = nil) {
        self.region = region
        self.style = style
        self.effect = effect
    }
}

/// Widths across a person's outline, to tell how much a redraw reshaped them.
public enum ShapeMeasure {
    /// A body's shoulders (its widest row 15–35% of the way down) and waist (its narrowest 45–70% down), in pixels.
    public static func body(_ mask: MaskData) -> (shoulders: Double, waist: Double)? {
        guard let rows = rows(mask) else { return nil }
        let shoulders = band(rows, 0.15, 0.35).max(), waist = band(rows, 0.45, 0.70).filter { $0 > 0 }.min()
        guard let shoulders, let waist, shoulders > 0 else { return nil }
        return (Double(shoulders), Double(waist))
    }

    /// A face's jaw (its width 80% of the way down) over its cheeks (its widest row 35–55% down).
    public static func face(_ mask: MaskData) -> Double? {
        guard let rows = rows(mask), let cheeks = band(rows, 0.35, 0.55).max(), cheeks > 0 else { return nil }
        let jaw = band(rows, 0.78, 0.82).max() ?? 0
        return Double(jaw) / Double(cheeks)
    }

    /// How much `after` changed against `before` on what `part` measures, each as a share: +0.06 is 6% wider.
    public static func change(_ part: PersonStyle.Part, before: MaskData, after: MaskData) -> [(name: String, change: Double)]? {
        switch part {
        case .body:
            guard let was = body(before), let now = body(after), was.waist > 0 else { return nil }
            return [("shoulders", now.shoulders / was.shoulders - 1), ("waist", now.waist / was.waist - 1)]
        case .face, .head:
            guard let was = face(before), let now = face(after), was > 0 else { return nil }
            return [("jaw", now / was - 1)]
        }
    }

    /// The covered pixels in each row of the mask's covered rows, top to bottom.
    private static func rows(_ mask: MaskData) -> [Int]? {
        let width = mask.size.width
        var counts: [Int] = []
        for y in 0..<mask.size.height {
            counts.append((0..<width).reduce(0) { $0 + (mask.coverage[y * width + $1] >= 128 ? 1 : 0) })
        }
        guard let top = counts.firstIndex(where: { $0 > 0 }), let bottom = counts.lastIndex(where: { $0 > 0 }),
              bottom - top >= 9 else { return nil }
        return Array(counts[top...bottom])
    }

    private static func band(_ rows: [Int], _ from: Double, _ to: Double) -> ArraySlice<Int> {
        let start = Int((Double(rows.count) * from).rounded(.down))
        let end = max(start + 1, Int((Double(rows.count) * to).rounded(.up)))
        return rows[min(start, rows.count - 1)..<min(end, rows.count)]
    }
}
