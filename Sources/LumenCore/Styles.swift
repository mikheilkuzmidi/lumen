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
    /// An instruction that asks for it, for an app to offer.
    public var example: String
    /// What else of the person is redrawn with the part. A face aged 30 years on a young neck, or zombie make-up that
    /// stopped at the jaw, showed where the face's mask ended.
    public var pieces: Set<Piece>
    /// The change to the rest of the person's bare skin (hands, arms, a bare chest), redrawn apart in its own close-up so
    /// the face keeps its detail; nil leaves it as it is.
    public var skinChange: String?
    /// A body's build drawn inside its outline after the warp has moved it, where the build shows (no top, or a fitted
    /// one). Asked for broader shoulders again over a warped body, Muse Image drew them back as they had been.
    public var buildChange: String?
    /// Whether the redraw keeps the part's outline where it is: it is placed only inside it, a little in from its edge.
    public var keepsOutline = false

    /// A part of a person a style redraws besides its own, found on them or, for what isn't there yet, made room for.
    public enum Piece: String, CaseIterable, Sendable {
        /// Their neck and ears: the bare skin by the face, down to their clothes.
        case neck
        /// The rest of their bare skin: hands, arms, a bare chest.
        case skin
        /// The clothes on their upper body.
        case top
        /// Room just above their head, for a hat or anything worn on it.
        case hat

        /// The piece in the words of a prompt.
        var words: String {
            switch self {
            case .neck: "their neck and ears"
            case .skin: "their bare hands and arms"
            case .top: "the clothes on their upper body"
            case .hat: "the space just above their head, for what they wear on it"
            }
        }
    }

    public struct Reshape: Equatable, Sendable {
        public var shoulders: Double
        public var waist: Double

        public init(shoulders: Double, waist: Double) {
            self.shoulders = shoulders
            self.waist = waist
        }
    }

    public init(id: String, title: String, part: Part, change: String, adultsOnly: Bool, limits: ShapeLimits? = nil,
                effect: String? = nil, reshape: Reshape? = nil, redraws: Bool = true, pieces: Set<Piece> = [],
                skinChange: String? = nil, buildChange: String? = nil, example: String = "") {
        self.id = id
        self.example = example
        self.pieces = pieces
        self.skinChange = skinChange
        self.buildChange = buildChange
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
                    change: "Give this person a clearly visible, chiselled \"Chad\" look: a stronger, squarer jaw about 10% "
                        + "wider at its corners, a firmer, more prominent chin, defined cheekbones with a slight hollow "
                        + "below them, a focused, confident gaze under slightly lowered brows, and short, even stubble along "
                        + "the jaw, chin and upper lip.",
                    adultsOnly: true, limits: ShapeLimits(least: 0.05, most: 0.2, measures: "jaw"), pieces: [.neck],
                    example: "Give the person a chad face"),
        PersonStyle(id: "gigachad", title: "Gigachad", part: .face,
                    change: "Turn this person into the \"Gigachad\" meme: a very strong, wide, square jaw and chin, sharply "
                        + "defined cheekbones and brow ridge, an intense stare and a short dark beard shadow.",
                    adultsOnly: true, limits: ShapeLimits(least: 0, most: 0.3, measures: "jaw"), effect: "monoDrama",
                    pieces: [.neck], example: "Make the person a gigachad"),
        PersonStyle(id: "hollywood", title: "Hollywood glow-up", part: .face,
                    change: "Give this person a clearly visible red-carpet glow-up, as a film's make-up artist and retoucher "
                        + "would before a premiere: luminous, even skin with a healthy glow, redness and blemishes gone but "
                        + "its texture and pores kept, neatly groomed fuller brows, bright clear eyes, white teeth if they "
                        + "show, and soft contouring under the cheekbones.",
                    adultsOnly: true, effect: "redCarpet", pieces: [.neck],
                    example: "Give the person a Hollywood glow-up"),
        PersonStyle(id: "beard", title: "Full beard", part: .face,
                    change: "Give this person a full, well-groomed beard and moustache in the colour of their own hair, "
                        + "growing down under the jaw onto the neck as a real beard does.",
                    adultsOnly: true, pieces: [.neck],
                    example: "Give the man a full beard"),
        PersonStyle(id: "older", title: "30 years older", part: .head,
                    change: "Show this person clearly about 30 years older, the same face and features grown older: crow's "
                        + "feet at the eyes, slightly heavier eyelids, deeper lines from the nose to the corners of the mouth, "
                        + "forehead lines, softer, less firm skin along the jaw and a creased, older neck, and thinner, "
                        + "greying hair.",
                    adultsOnly: true, pieces: [.neck, .skin],
                    skinChange: "Make the skin of this person's hands and arms about 30 years older, to match an older "
                        + "face: thinner, slightly creased skin, a few age spots and more visible veins.",
                    example: "Make the person look 30 years older"),
        PersonStyle(id: "smile", title: "Big smile", part: .face,
                    change: "Change this person's expression to a natural, wide smile that reaches the eyes, showing the teeth.",
                    adultsOnly: false,
                    example: "Make the person smile big"),
        PersonStyle(id: "shades", title: "Aviator shades", part: .face,
                    change: "Put a pair of classic aviator sunglasses on this person, sitting naturally on the nose, "
                        + "with real reflections of the scene in the lenses.",
                    adultsOnly: false,
                    example: "Put aviator sunglasses on the person"),
        PersonStyle(id: "zombie", title: "Zombie make-up", part: .face,
                    change: "Give this person Halloween zombie make-up on the same face, down the neck and over the ears: "
                        + "pale grey-green skin, dark sunken eyes and painted scars.",
                    adultsOnly: false, pieces: [.neck, .skin],
                    skinChange: "Cover this person's hands and arms in grey-green theatrical body paint, the kind worn "
                        + "with a Halloween costume, applied evenly.",
                    example: "Give the person zombie make-up for Halloween"),
        PersonStyle(id: "platinum", title: "Platinum blonde", part: .head,
                    change: "Dye this person's hair a bright platinum blonde, a solid, fully dyed colour from the roots to "
                        + "the tips, keeping its cut, length and texture.",
                    adultsOnly: false,
                    example: "Dye the person's hair platinum blonde"),
        PersonStyle(id: "vampire", title: "Vampire", part: .head,
                    change: "Turn this person into a classic vampire for Halloween: very pale, cool-toned skin on the face, "
                        + "neck and ears, dark shadows around red-tinted eyes, slicked-back hair, and a black cape with a "
                        + "tall, stiff collar lined in deep red standing up behind the neck, over a dark high-collared shirt.",
                    adultsOnly: false, pieces: [.neck, .top, .skin],
                    skinChange: "Give this person's hands and arms the same very pale, cool-toned theatrical make-up as "
                        + "their face, as worn with a Halloween vampire costume.",
                    example: "Turn the person into a vampire"),
        PersonStyle(id: "pirate", title: "Pirate captain", part: .head,
                    change: "Dress this person as a pirate captain: a black tricorn hat with gold trim on their head, a "
                        + "black eye patch over one eye, a short dark beard, and a long deep-red captain's coat with gold "
                        + "buttons over a loose white shirt.",
                    adultsOnly: false, pieces: [.neck, .top, .hat],
                    example: "Dress the person as a pirate captain"),
        PersonStyle(id: "costume", title: "Costume", part: .head,
                    change: "Dress this person up as {outfit}: a convincing, well-made costume, worn naturally.",
                    adultsOnly: false, pieces: [.neck, .top],
                    skinChange: "Make the bare skin of this person's hands and arms match their costume, {outfit}, "
                        + "only where the costume changes skin.",
                    example: "Dress the person up as a medieval knight"),
        PersonStyle(id: "athletic", title: "Athletic build", part: .body,
                    change: "Make this person clearly more athletic, as after a few months of training: shoulders about 10% "
                        + "broader and waist about 10% narrower for a visible V-shaped torso, a firmer chest and more "
                        + "defined arms, their clothes fitting the new shape.",
                    adultsOnly: true, limits: ShapeLimits(least: 0.02, most: 0.15, measures: "shoulders and waist", widestWaist: 0.02),
                    reshape: Reshape(shoulders: 0.1, waist: -0.1), redraws: false,
                    buildChange: "Give this person a visibly more athletic build, as after a few months of training: a "
                        + "firmer, more defined chest, defined shoulders, and toned, defined arms where skin shows.",
                    example: "Make the person's body athletic, a realistic V-taper"),
        PersonStyle(id: "muscular", title: "Gym-built", part: .body,
                    change: "Show this same person after a year of strength training: noticeably broader shoulders and "
                        + "thicker, defined arms, a stronger build filling out their clothes.",
                    adultsOnly: true, limits: ShapeLimits(least: 0.03, most: 0.2, measures: "shoulders and waist", widestWaist: 0.08),
                    reshape: Reshape(shoulders: 0.15, waist: -0.05),
                    buildChange: "Show this same person after a year of strength training: a fuller, firmer, clearly "
                        + "muscular chest, rounded, defined shoulders, and thicker, muscular arms where skin shows.",
                    example: "Make the person look gym-built but believable"),
    ]

    /// What Muse Image is asked: the change, which part of whom and where, what stays, and how to fill where the
    /// outline moves in. Said outright, with amounts: asked for "slightly broader shoulders, not a bodybuilder", it
    /// changed nothing. With `pieces`, it is told every part it redraws; with what a body `wears`, how its new shape
    /// shows.
    public func prompt(person: String, place: String, firmer: Firmness = .asked, pieces: Set<Piece> = [],
                       wears attire: Attire? = nil) -> String {
        let part = switch self.part {
        case .face: "face"
        case .head: "head and hair"
        case .body: "body"
        }
        var text = change
        if self.part == .body, let attire { text += " " + attire.shows }
        switch firmer {
        case .asked: break
        case .subtler: text += " Make the change subtler, about half as much: it went too far."
        case .stronger: text += " Make the change clearly visible: it was too slight to see."
        case .sameTone: text += " Keep the skin exactly the photo's own tone, light and colour cast: the last try came out a different tone, which shows as a seam."
        case .samePose: text += " Keep their pose and outline exactly: the last try drew arms or hands that aren't in the photo, or moved the body's edge. Draw none where none show, and keep every edge where it is."
        }
        // Told to keep exactly the photo's skin tone, a face asked to age greyed its hair and kept its young skin.
        let stays = self.part == .body
            ? "Keep their face, pose and clothes and the background the same."
            : dressesUp ? "The costume replaces what they wore there completely, with no trace of the old clothes, their "
                + "logos or prints. Keep the same person, clearly recognisable, in their own pose and the photo's own light."
            : keepsTone ? "Keep the same person, clearly recognisable, with exactly the photo's skin tone, colours and light."
            : "Keep the same person, clearly recognisable, in the photo's own light."
        let parts = ["their \(part)"] + Piece.allCases.filter { $0 != .skin && pieces.contains($0) }.map(\.words)
        let only = parts.count == 1
            ? "Change only the \(part) of the \(person) \(place) of this picture"
            : "Change only these parts of the \(person) \(place) of this picture: \(parts.joined(separator: "; "))"
        return "Edit this photo. \(text) \(only); keep everything else exactly as it is. \(stays) Where the outline "
            + "moves in, continue the background behind it. Photorealistic."
    }

    /// What Muse Image is asked for the person's other bare skin, in its own close-up; nil for a style that leaves it.
    /// `handsOnly` names the hands alone: Meta's content filter turned down body paint on "hands and arms" every time
    /// and let the same paint on "hands" through.
    public func skinPrompt(person: String, place: String, handsOnly: Bool = false) -> String? {
        guard var change = skinChange else { return nil }
        var parts = "hands and arms of the \(person) \(place) of this picture"
        if handsOnly {
            change = change.replacingOccurrences(of: "hands and arms", with: "hands")
            parts = "hands in this picture"
        }
        return "Edit this photo. \(change) Change only the bare skin of the \(parts); keep their clothes, their pose, what "
            + "they hold or wear and everything else exactly as it is, in the photo's own light. Photorealistic."
    }

    /// The costume style dressed as `outfit`, as the planner put it.
    public func dressed(as outfit: String) -> PersonStyle {
        var style = self
        style.change = change.replacingOccurrences(of: "{outfit}", with: outfit)
        style.skinChange = skinChange?.replacingOccurrences(of: "{outfit}", with: outfit)
        return style
    }

    /// The body style as its build is drawn inside an outline the warp already moved: the build only, placed inside that
    /// outline so it can't move it; nil for a style with no build to draw.
    public func built() -> PersonStyle? {
        guard part == .body, let buildChange else { return nil }
        var style = self
        style.change = buildChange + " Their outline is already the new shape: keep its width, size and every edge "
            + "exactly where they are, and draw the build inside it. Keep their pose exactly: arms and hands only where "
            + "they are now, and none added where none show."
        style.limits = nil
        style.reshape = nil
        style.buildChange = nil
        style.keepsOutline = true
        return style
    }

    /// Whether it dresses the person up, changing their outline with new clothes or a hat: found again in the redraw,
    /// their head is no longer the shape it was, and that is the point.
    public var dressesUp: Bool { pieces.contains(.top) || pieces.contains(.hat) }

    public enum Firmness: Sendable { case asked, subtler, stronger, sameTone, samePose }

    /// Whether the part keeps the photo's own colour: all but those that recolour it (make-up, dyed or greying hair, a
    /// costume).
    public var keepsTone: Bool { !["zombie", "platinum", "older", "vampire"].contains(id) && !dressesUp }

    /// Whether a head's mask must also cover the face under the hair: SAM's "head" was sometimes only the hair.
    public var coversFace: Bool { part == .head && id != "platinum" }
}

/// What a person wears on their upper body, which decides what a body style can show of their new build.
public enum Attire: String, CaseIterable, Sendable {
    /// No top: their chest, shoulders and arms are bare.
    case bare
    /// A T-shirt, tank top or thin shirt, which the body's shape shows through.
    case fitted
    /// A jacket, coat, hoodie or sweater, which hides it.
    case loose

    /// What it is, in a note for the critic.
    var words: String {
        switch self {
        case .bare: "no top"
        case .fitted: "a fitted top"
        case .loose: "loose clothes"
        }
    }

    /// Whether the build shows, so the image model redraws it as well as the warp moving its outline.
    public var showsBuild: Bool { self != .loose }

    /// How the new build shows, said to Muse Image.
    var shows: String {
        switch self {
        case .bare: "They are shirtless: give their bare chest, shoulders and arms natural, visible muscle definition, "
            + "evenly on both sides, in their own skin tone and the photo's light."
        case .fitted: "They wear a fitted top: show the new chest and shoulders through it, the fabric following the "
            + "body's shape, and make any bare arms defined, evenly on both sides."
        case .loose: "Their loose clothes hide the build: show it in the outline and the fit of the clothes."
        }
    }
}

/// How much a style may change the outline it measures, as a share of its width: at least `least` to be seen, at most
/// `most` to stay believable.
public struct ShapeLimits: Equatable, Sendable {
    public var least: Double
    public var most: Double
    /// What is measured, in words.
    public var measures: String
    /// How much wider a body's waist may come out, whatever the largest change: a muscle redraw widened a slim man's
    /// waist by a fifth, within "up to 20%", and it read as heavier, not gym-built.
    public var widestWaist: Double?

    public init(least: Double, most: Double, measures: String, widestWaist: Double? = nil) {
        self.least = least
        self.most = most
        self.measures = measures
        self.widestWaist = widestWaist
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
    /// An instruction that asks for it, for an app to offer.
    public var example: String
    public var parts: [Part]

    /// Whether it needs a person to work on.
    public var needsPerson: Bool { parts.contains { $0.target != .photo } }

    public static func named(_ id: String) -> StyleEffect? { all.first { $0.id == id } }

    public static let all: [StyleEffect] = [
        StyleEffect(id: "monoDrama", title: "Dramatic black and white", example: "Make it dramatic black and white", parts: [
            Part(target: .photo, values: [.saturation: -100, .contrast: 45, .clarity: 35, .blacks: -20, .highlights: -20]),
        ]),
        StyleEffect(id: "mainCharacter", title: "Main character", example: "Make it a main character shot", parts: [
            Part(target: .background, values: [.exposure: -0.5, .saturation: -20]),
            Part(target: .person, values: [.exposure: 0.15]),
            Part(target: .photo, values: [.highlightWarmth: 15, .shadowWarmth: -15]),
        ]),
        StyleEffect(id: "vintage", title: "Vintage film", example: "Give the photo a vintage film look", parts: [
            Part(target: .photo, values: [.contrast: -15, .blacks: 20, .saturation: -25, .highlightWarmth: 12, .highlights: -15]),
        ]),
        StyleEffect(id: "neonNight", title: "Neon night", example: "Give it a neon night look", parts: [
            Part(target: .photo, values: [.tint: 25, .temperature: -20, .contrast: 20, .vibrance: 30, .shadows: -15]),
        ]),
        // Hollywood's own: Muse Image gave an already clear-skinned face back unchanged three times in three, so the
        // glow-up is also a soft, warm light on the person, with what is behind them a little darker.
        StyleEffect(id: "redCarpet", title: "Red carpet glow", example: "Give the person a red carpet glow", parts: [
            Part(target: .person, values: [.exposure: 0.15, .clarity: -15, .highlightWarmth: 12, .vibrance: 10]),
            Part(target: .background, values: [.exposure: -0.2, .saturation: -10]),
        ]),
    ]
}

/// Restyle a selected person: one of `PersonStyle.all`, one of `StyleEffect.all`, or both. A style needs the region of
/// the person; an effect on the photo alone needs none.
public struct StyleStep: Codable, Equatable, Sendable {
    public var region: String?
    public var style: String?
    public var effect: String?
    /// A selected thing the person holds in front of them (a fish, a bag, a baby), left as it is when their body is
    /// reshaped or redrawn: a warp widening a man bent the big fish held against his chest.
    public var keep: String?
    /// What the person wears on their upper body (an `Attire`), for a body style: a bare or T-shirted chest and arms
    /// are redrawn with the new build, evenly; a jacket only moves its outline.
    public var wears: String?
    /// More of the person to redraw than the style covers by itself (`PersonStyle.Piece`s): a costume's clothes or hat.
    public var with: [String]?
    /// The costume style's costume, in a few words.
    public var outfit: String?

    public init(region: String? = nil, style: String? = nil, effect: String? = nil, keep: String? = nil,
                wears: String? = nil, with: [String]? = nil, outfit: String? = nil) {
        self.region = region
        self.style = style
        self.effect = effect
        self.keep = keep
        self.wears = wears
        self.with = with
        self.outfit = outfit
    }
}

/// Where a person's shoulders and waist are, measured down from their chin in face heights, so it holds whether they
/// stand or sit, and whether the photo shows all of them or cuts them off at the thighs. Shares of the outline's
/// height took a man's hair for his shoulders, in a half-length photo where his friends' arms covered them, and the
/// warp widened his head.
public struct BodyFrame: Equatable, Sendable {
    /// The face's lowest row.
    public var chin: Int
    /// The face's height, forehead to chin, in rows.
    public var face: Double

    /// The frame of the face in `face`, in the same rows as the body it belongs to; nil for a face too small to measure.
    public init?(face mask: MaskData) {
        let width = mask.size.width
        let covered = (0..<mask.size.height).filter { y in (0..<width).contains { mask.coverage[y * width + $0] >= 128 } }
        guard let top = covered.first, let bottom = covered.last, bottom - top >= 3 else { return nil }
        chin = bottom
        face = Double(bottom - top + 1)
    }

    public init(chin: Int, face: Double) {
        self.chin = chin
        self.face = face
    }

    /// Where the shoulders' widest row is: a third of a face to a face and a half below the chin.
    public var shoulders: ClosedRange<Int> { (chin + Int(face * 0.3))...(chin + Int(face * 1.6)) }
    /// The waist's row, 2.3 faces below the chin: about two head heights, as on an adult figure.
    public var waist: Int { chin + Int(face * 2.3) }
    /// How much of a row below the chin a change may reach: none at the chin, all of it a third of a face below.
    public func reach(_ row: Int) -> Double {
        let t = min(1, max(0, Double(row - chin) / (face * 0.3)))
        return t * t * (3 - 2 * t)
    }
}

/// Widths across a person's outline, to tell how much a redraw reshaped them.
public enum ShapeMeasure {
    /// A body's shoulders and waist, in pixels: with its `frame`, the widest row where the shoulders are and the narrowest
    /// within half a face of the waist; without, its widest row 15–35% of the way down and its narrowest 45–70% down.
    public static func body(_ mask: MaskData, frame: BodyFrame? = nil) -> (shoulders: Double, waist: Double)? {
        if let frame {
            let width = mask.size.width, height = mask.size.height
            func count(_ y: Int) -> Int { (0..<width).reduce(0) { $0 + (mask.coverage[y * width + $1] >= 128 ? 1 : 0) } }
            let reach = Int(frame.face * 0.5)
            let shoulders = frame.shoulders.clamped(to: 0...(height - 1)).map(count).max()
            let waist = ((frame.waist - reach)...(frame.waist + reach)).clamped(to: 0...(height - 1)).map(count).filter { $0 > 0 }.min()
            guard let shoulders, let waist, shoulders > 0, frame.shoulders.lowerBound < height, frame.waist - reach < height else {
                return nil
            }
            return (Double(shoulders), Double(waist))
        }
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
    public static func change(_ part: PersonStyle.Part, before: MaskData, after: MaskData,
                              frame: BodyFrame? = nil) -> [(name: String, change: Double)]? {
        switch part {
        case .body:
            guard let was = body(before, frame: frame), let now = body(after, frame: frame), was.waist > 0 else { return nil }
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
