import Foundation

// Editing a whole library at once: every photo gets the same base pass (look, flag misfires, auto, straighten),
// photos that still score low get a closer look, and an instruction ("make all their shirts blue") is planned
// across the library, with questions for the person where the choice is theirs.

/// How much the batch agent decides on its own.
public enum BatchMode: String, Codable, Sendable, CaseIterable {
    /// Decides everything itself, taking each question's recommended answer and noting that it did.
    case autonomous
    /// Works on its own but stops to ask when a decision is the person's to make.
    case askWhenUnsure = "ask"
    /// Looks at the library, asks its questions and shows the plan, then waits for approval before changing anything.
    case planFirst = "plan"
}

/// What the person asked for, and how far the agent may go.
public struct BatchOptions: Codable, Equatable, Sendable {
    public var mode: BatchMode
    /// An edit for the whole library, such as "make all their shirts blue"; nil runs only the base pass.
    public var instruction: String?
    /// Automatic tone and colour on every photo that is kept.
    public var auto: Bool
    /// Level tilted horizons: true for every tilted photo, false never, nil to decide (asking unless autonomous).
    public var straighten: Bool?
    /// Mark misfired shots (badly blurred, black, accidental) and leave them out of the rest.
    public var flagMisfires: Bool
    /// Photos whose quality, 0...1, is below this after the base pass get a closer look of their own.
    public var qualityThreshold: Double
    /// Photos edited at the same time.
    public var concurrency: Int
    /// Stop before making more model calls than this; nil has no limit.
    public var maxModelCalls: Int?

    public init(mode: BatchMode = .askWhenUnsure, instruction: String? = nil, auto: Bool = true, straighten: Bool? = nil,
                flagMisfires: Bool = true, qualityThreshold: Double = 0.5, concurrency: Int = 3, maxModelCalls: Int? = nil) {
        self.mode = mode
        self.instruction = instruction
        self.auto = auto
        self.straighten = straighten
        self.flagMisfires = flagMisfires
        self.qualityThreshold = qualityThreshold
        self.concurrency = concurrency
        self.maxModelCalls = maxModelCalls
    }
}

/// A photo in a library, named by its host (a file name, a catalog id).
public struct PhotoID: Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

/// What can be measured on a photo without a model.
public struct PhotoFacts: Codable, Equatable, Sendable {
    public var size: PixelSize
    /// Fine detail, 0 (no edges at all) to 1 (crisp).
    public var sharpness: Double
    /// Mean lightness, 0...1.
    public var exposure: Double
    /// Shares of the photo that are pure black and pure white.
    public var clippedShadows: Double
    public var clippedHighlights: Double
    /// The horizon's tilt in degrees, positive counterclockwise, when one was found.
    public var tilt: Double?
    public var capturedAt: Date?

    public init(size: PixelSize, sharpness: Double, exposure: Double, clippedShadows: Double = 0, clippedHighlights: Double = 0,
                tilt: Double? = nil, capturedAt: Date? = nil) {
        self.size = size
        self.sharpness = sharpness
        self.exposure = exposure
        self.clippedShadows = clippedShadows
        self.clippedHighlights = clippedHighlights
        self.tilt = tilt
        self.capturedAt = capturedAt
    }
}

/// A library of photos the batch agent can look at and change. Lumen's folder library is one; an editor's
/// catalog can be another.
public protocol LibraryHost: Sendable {
    /// The photos to work on, in the library's order.
    func photos() async throws -> [PhotoID]
    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage
    func facts(_ photo: PhotoID) async throws -> PhotoFacts
    /// The host's own automatic tone and colour. Returns what it did, in words: "Auto: exposure +0.3, …".
    func applyAuto(_ photo: PhotoID) async throws -> String
    /// Rotates the photo by `degrees` (positive counterclockwise) and crops to keep it rectangular.
    func straighten(_ photo: PhotoID, degrees: Double) async throws
    /// Marks a photo as a misfire, with the reason; the photo itself is kept.
    func flag(_ photo: PhotoID, reason: String) async throws
    /// The photo as an edit host, for the agent that edits one photo.
    func editHost(_ photo: PhotoID) async throws -> any EditHost
    /// Keeps the photo's edits (writes them or exports the result).
    func save(_ photo: PhotoID) async throws
}

/// A photo as the reviewer is shown it.
public struct ReviewPhoto: Sendable {
    public var photo: PhotoID
    public var thumbnail: EncodedImage
    public var facts: PhotoFacts

    public init(photo: PhotoID, thumbnail: EncodedImage, facts: PhotoFacts) {
        self.photo = photo
        self.thumbnail = thumbnail
        self.facts = facts
    }
}

public struct ReviewRequest: Sendable {
    public var instruction: String?
    /// Up to 20 photos, looked at together.
    public var photos: [ReviewPhoto]

    public init(instruction: String?, photos: [ReviewPhoto]) {
        self.instruction = instruction
        self.photos = photos
    }
}

/// One photo, as the reviewer judged it.
public struct PhotoReview: Codable, Equatable, Sendable {
    public var photo: PhotoID
    /// A shot that went wrong: badly blurred, black, a pocket shot, eyes closed in a portrait series.
    public var misfire: Bool
    public var misfireReason: String?
    /// How good the photo is as it stands, 0...1.
    public var quality: Double
    /// What it shows, in a few words: "four friends outdoors, red and grey shirts".
    public var description: String
    /// Photos with the same key show the same scene or subjects.
    public var group: String
    /// Whether the instruction applies to this photo.
    public var matchesInstruction: Bool

    public init(photo: PhotoID, misfire: Bool, misfireReason: String? = nil, quality: Double, description: String,
                group: String, matchesInstruction: Bool) {
        self.photo = photo
        self.misfire = misfire
        self.misfireReason = misfireReason
        self.quality = quality
        self.description = description
        self.group = group
        self.matchesInstruction = matchesInstruction
    }
}

/// A decision that is the person's to make, with the agent's recommendation.
public struct BatchQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var question: String
    public var options: [String]
    /// Index into `options`.
    public var recommended: Int
    /// The groups the answer changes.
    public var groups: [String]

    public init(id: String, question: String, options: [String], recommended: Int, groups: [String] = []) {
        self.id = id
        self.question = question
        self.options = options
        self.recommended = recommended
        self.groups = groups
    }
}

/// Photos that get the same edit.
public struct BatchGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var photos: [PhotoID]
    /// The instruction each photo's agent is given; nil when the base pass is enough.
    public var instruction: String?

    public init(id: String, title: String, photos: [PhotoID], instruction: String?) {
        self.id = id
        self.title = title
        self.photos = photos
        self.instruction = instruction
    }
}

public struct BatchPlan: Codable, Equatable, Sendable {
    public var summary: String
    public var groups: [BatchGroup]
    /// Open questions; a plan written with every answer has none.
    public var questions: [BatchQuestion]

    public init(summary: String, groups: [BatchGroup], questions: [BatchQuestion] = []) {
        self.summary = summary
        self.groups = groups
        self.questions = questions
    }
}

public struct BatchPlanRequest: Sendable {
    public var instruction: String
    public var reviews: [PhotoReview]
    /// Answers so far, by question id: the chosen option's text.
    public var answers: [String: String]

    public init(instruction: String, reviews: [PhotoReview], answers: [String: String] = [:]) {
        self.instruction = instruction
        self.reviews = reviews
        self.answers = answers
    }
}

/// Looks at many photos at once and plans an instruction across them.
public protocol BatchPlanner: Sendable {
    /// The model that looks at the photos.
    var modelID: String { get }
    /// The model that plans across the library; the reviewing model unless a planner says otherwise.
    var planModelID: String { get }
    func review(_ request: ReviewRequest) async throws -> [PhotoReview]
    /// Groups the photos the instruction applies to and writes each group's instruction, asking what it cannot decide.
    func plan(_ request: BatchPlanRequest) async throws -> BatchPlan
}

extension BatchPlanner {
    public var planModelID: String { modelID }
}

/// How one photo came out.
public struct BatchPhotoResult: Codable, Equatable, Sendable {
    public var photo: PhotoID
    public var flagged: String?
    public var auto: String?
    public var straightened: Double?
    public var instruction: String?
    /// The per-photo agent's last word, or why it stopped.
    public var outcome: String?
    public var failed: Bool

    public init(photo: PhotoID, flagged: String? = nil, auto: String? = nil, straightened: Double? = nil,
                instruction: String? = nil, outcome: String? = nil, failed: Bool = false) {
        self.photo = photo
        self.flagged = flagged
        self.auto = auto
        self.straightened = straightened
        self.instruction = instruction
        self.outcome = outcome
        self.failed = failed
    }
}

public struct BatchSummary: Codable, Equatable, Sendable {
    public var photos: [BatchPhotoResult]
    /// Each question with the answer used and whether the person gave it.
    public var answers: [BatchAnswer]
    public var modelCalls: Int
    public var duration: TimeInterval

    public init(photos: [BatchPhotoResult], answers: [BatchAnswer], modelCalls: Int, duration: TimeInterval) {
        self.photos = photos
        self.answers = answers
        self.modelCalls = modelCalls
        self.duration = duration
    }
}

public struct BatchAnswer: Codable, Equatable, Sendable {
    public var question: BatchQuestion
    public var answer: String
    /// False when the agent took the recommended option itself.
    public var byPerson: Bool

    public init(question: BatchQuestion, answer: String, byPerson: Bool) {
        self.question = question
        self.answer = answer
        self.byPerson = byPerson
    }
}

/// What the batch agent reports while it works.
public enum BatchEvent: Sendable {
    case found(count: Int)
    case measured(PhotoID, PhotoFacts)
    case reviewed(PhotoReview)
    case flagged(PhotoID, reason: String)
    case autoApplied(PhotoID, label: String)
    case straightened(PhotoID, degrees: Double)
    case planned(BatchPlan)
    /// Waits for `BatchAgent.answer(_:with:)` unless the mode is autonomous.
    case question(BatchQuestion)
    case answered(BatchAnswer)
    /// Plan-first mode: waits for `BatchAgent.approve()`.
    case awaitingApproval(BatchPlan, estimatedModelCalls: Int)
    case editStarted(PhotoID, instruction: String)
    /// An event from the agent editing one photo.
    case edit(PhotoID, AgentEvent)
    case editFinished(BatchPhotoResult)
    case progress(done: Int, total: Int)
    case finished(BatchSummary)
    case trace(TraceEvent)
}
