import Foundation
import Testing
@testable import LumenCore

let batchTestImage = EncodedImage(
    data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6X8AAAAASUVORK5CYII=")!,
    format: .png, size: PixelSize(width: 1, height: 1))

/// A photo's facts; unless its lines are given, its upright lines lean with its horizon, as a rolled camera's do.
func batchTestFacts(sharpness: Double = 0.9, exposure: Double = 0.5, tilt: Double? = nil, verticalLean: Double? = nil,
                    levelTilt: Double? = nil, noLines: Bool = false) -> PhotoFacts {
    let rolled = verticalLean == nil && levelTilt == nil && !noLines
    return PhotoFacts(size: batchTestImage.size, sharpness: sharpness, exposure: exposure, tilt: tilt,
                      verticalLean: rolled ? tilt : verticalLean, levelTilt: levelTilt)
}

func batchTestReview(_ photo: PhotoID, quality: Double = 0.9, misfire: Bool = false, matches: Bool = true,
                     tilted: Bool? = nil, levelLine: LevelLine? = nil) -> PhotoReview {
    PhotoReview(photo: photo, misfire: misfire, misfireReason: misfire ? "Badly blurred" : nil, quality: quality,
                description: "A person in a shirt", group: "people", matchesInstruction: matches, tilted: tilted,
                levelLine: levelLine)
}

func batchTestAgent(_ library: BatchTestLibrary, reviewer: (any BatchPlanner)? = nil,
                    planner: BatchTestPlanner = BatchTestPlanner(), segmenter: BatchTestSegmenter = BatchTestSegmenter(),
                    generator: BatchTestGenerator = BatchTestGenerator()) -> BatchAgent {
    BatchAgent(host: library, reviewer: reviewer, planner: planner, segmenter: segmenter, generator: generator)
}

func batchTestCollect(_ stream: AsyncThrowingStream<BatchEvent, Error>) async throws -> [BatchEvent] {
    var events: [BatchEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

func batchTestSummary(_ events: [BatchEvent]) throws -> BatchSummary {
    try #require(events.compactMap { if case .finished(let summary) = $0 { summary } else { nil } }.last)
}

extension Array where Element == BatchEvent {
    var batchQuestions: [BatchQuestion] { compactMap { if case .question(let question) = $0 { question } else { nil } } }
    var batchEdits: [PhotoID] { compactMap { if case .editStarted(let photo, _) = $0 { photo } else { nil } } }
    var batchProgress: [Int] { compactMap { if case .progress(let done, _) = $0 { done } else { nil } } }
    var batchTraces: [TraceEvent] {
        compactMap {
            switch $0 {
            case .trace(let trace), .edit(_, .trace(let trace)): trace
            default: nil
            }
        }
    }
}

actor BatchTestLibrary: LibraryHost {
    let ids: [PhotoID]
    private let measurements: [PhotoID: PhotoFacts]
    private let factsGate: BatchTestGate?
    private let failingFacts: Set<PhotoID>
    private let failingAuto: Set<PhotoID>
    private let failingSave: Set<PhotoID>
    private let failingEditHost: Set<PhotoID>
    private(set) var measured: [PhotoID] = []
    private(set) var thumbnails: [(photo: PhotoID, edge: Int)] = []
    private(set) var flags: [PhotoID: String] = [:]
    private(set) var autos: [PhotoID] = []
    private(set) var rotations: [PhotoID: Double] = [:]
    private(set) var edited: [PhotoID] = []
    private(set) var saved: [PhotoID] = []
    private(set) var photoHosts: [PhotoID: BatchTestPhoto] = [:]
    private(set) var activeFacts = 0
    private(set) var peakFacts = 0

    init(_ measurements: [PhotoFacts], factsGate: BatchTestGate? = nil, failingFacts: Set<PhotoID> = [],
         failingAuto: Set<PhotoID> = [], failingSave: Set<PhotoID> = [], failingEditHost: Set<PhotoID> = []) {
        ids = measurements.indices.map { PhotoID("photo-\($0)") }
        self.measurements = Dictionary(uniqueKeysWithValues: zip(ids, measurements))
        self.factsGate = factsGate
        self.failingFacts = failingFacts
        self.failingAuto = failingAuto
        self.failingSave = failingSave
        self.failingEditHost = failingEditHost
    }

    func photos() async throws -> [PhotoID] { ids }

    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage {
        thumbnails.append((photo, maxLongEdge))
        return batchTestImage
    }

    func facts(_ photo: PhotoID) async throws -> PhotoFacts {
        measured.append(photo)
        activeFacts += 1
        peakFacts = max(peakFacts, activeFacts)
        await factsGate?.enter()
        activeFacts -= 1
        if failingFacts.contains(photo) { throw LumenError.invalidResponse("Cannot measure this photo.") }
        return measurements[photo]!
    }

    func applyAuto(_ photo: PhotoID) async throws -> String {
        if failingAuto.contains(photo) { throw LumenError.invalidResponse("Cannot apply auto.") }
        autos.append(photo)
        return "Auto: exposure +0.3"
    }

    func straighten(_ photo: PhotoID, degrees: Double) async throws { rotations[photo] = degrees }
    func flag(_ photo: PhotoID, reason: String) async throws { flags[photo] = reason }

    func editHost(_ photo: PhotoID) async throws -> any EditHost {
        edited.append(photo)
        if failingEditHost.contains(photo) { throw LumenError.invalidResponse("Cannot open this photo for editing.") }
        if let existing = photoHosts[photo] { return existing }
        let host = BatchTestPhoto()
        photoHosts[photo] = host
        return host
    }

    func save(_ photo: PhotoID) async throws {
        if failingSave.contains(photo) { throw LumenError.invalidResponse("Cannot save this photo.") }
        saved.append(photo)
    }
}

actor BatchTestPhoto: EditHost {
    private(set) var layers: [Layer] = []
    func size() async -> PixelSize { batchTestImage.size }
    func render(maxLongEdge: Int) async throws -> EncodedImage { batchTestImage }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage { batchTestImage }
    func apply(_ layer: Layer, assets: AssetStore) async throws { layers.append(layer) }
    func remove(_ layer: Layer.ID) async throws { layers.removeAll { $0.id == layer } }
}

actor BatchTestReviewer: BatchPlanner {
    let modelID = "muse-spark-1.3"
    private let reviews: [PhotoID: PhotoReview]
    private let plans: [BatchPlan]
    private let gate: BatchTestGate?
    private let repeatQuestions: Bool
    private let reviewResponse: [PhotoReview]?
    private let reviewError: (any Error)?
    private(set) var reviewRequests: [ReviewRequest] = []
    private(set) var planRequests: [BatchPlanRequest] = []
    private(set) var active = 0
    private(set) var peak = 0

    init(reviews: [PhotoReview] = [], plans: [BatchPlan] = [], gate: BatchTestGate? = nil, repeatQuestions: Bool = false,
         reviewResponse: [PhotoReview]? = nil, reviewError: (any Error)? = nil) {
        self.reviews = Dictionary(uniqueKeysWithValues: reviews.map { ($0.photo, $0) })
        self.reviewError = reviewError
        self.plans = plans
        self.gate = gate
        self.repeatQuestions = repeatQuestions
        self.reviewResponse = reviewResponse
    }

    func review(_ request: ReviewRequest) async throws -> [PhotoReview] {
        reviewRequests.append(request)
        active += 1
        peak = max(peak, active)
        await gate?.enter()
        active -= 1
        if let reviewError { throw reviewError }
        return reviewResponse ?? request.photos.map { reviews[$0.photo] ?? batchTestReview($0.photo) }
    }

    func plan(_ request: BatchPlanRequest) async throws -> BatchPlan {
        planRequests.append(request)
        if !plans.isEmpty { return plans[min(planRequests.count - 1, plans.count - 1)] }
        let question = BatchQuestion(id: "shirts", question: "Which blue?", options: ["Navy", "Sky blue"], recommended: 0)
        let questions = request.answers[question.id] == nil ? [question] : []
        let open = repeatQuestions ? [BatchQuestion(id: "round-\(planRequests.count)", question: "Which blue?",
                                                    options: question.options, recommended: 0)] : questions
        return BatchPlan(summary: "Colour the shirts", groups: [
            // Like the real planner, it takes the reviewer's hint about which photos the instruction applies to.
            BatchGroup(id: "people", title: "People", photos: request.reviews.filter(\.matchesInstruction).map(\.photo),
                       instruction: "Make the shirts \(request.answers["shirts"] ?? "navy")"),
        ], questions: open)
    }
}

actor BatchTestPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private let gate: BatchTestGate?
    private let failingPlanAt: Int?
    private let redraw: Bool
    private let noChange: Bool
    private let revisions: Int
    private(set) var plans: [PlanRequest] = []
    private(set) var critiques: [CritiqueRequest] = []
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var cancellations = 0

    init(gate: BatchTestGate? = nil, failingPlanAt: Int? = nil, redraw: Bool = false, noChange: Bool = false, revisions: Int = 0) {
        self.gate = gate
        self.failingPlanAt = failingPlanAt
        self.redraw = redraw
        self.noChange = noChange
        self.revisions = revisions
    }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        plans.append(request)
        let index = plans.count
        active += 1
        peak = max(peak, active)
        await gate?.enter()
        active -= 1
        if Task.isCancelled { cancellations += 1 }
        await gate?.leave()
        if index == failingPlanAt { throw LumenError.refused("Cannot edit this photo.") }
        if noChange { return EditPlan(summary: "Keep it", steps: []) }
        if redraw {
            return EditPlan(summary: "Blue shirt", steps: [
                .select(Selection(id: "shirt", concept: "shirt")),
                .regenerate(Regeneration(region: "shirt", prompt: "a blue shirt")),
            ])
        }
        return EditPlan(summary: "Improve exposure", steps: [.adjust(Adjustment(values: [.exposure: 0.3]))])
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiques.append(request)
        if critiques.count <= revisions {
            return Critique(satisfied: false, notes: "More contrast", steps: [.adjust(Adjustment(values: [.contrast: 3]))])
        }
        return Critique(satisfied: true, notes: "Looks natural.")
    }
}

actor BatchTestSegmenter: Segmenter {
    let modelID = "sam-3.1"
    /// How many of the first requests find nothing.
    private let findsNothing: Int
    private(set) var requests: [SegmentRequest] = []
    init(findsNothing: Int = 0) { self.findsNothing = findsNothing }
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        if requests.count <= findsNothing { return [] }
        return [Segment(label: "shirt", box: .whole, mask: MaskData(size: request.image.size, filledWith: 255))]
    }
}

actor BatchTestGenerator: Generator {
    let modelID = "muse-image-1.0"
    private(set) var requests: [GenerateRequest] = []
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        requests.append(request)
        return request.image
    }
}

/// Pauses fake work until the test has observed the desired number of concurrent calls.
actor BatchTestGate {
    private var entered = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [(count: Int, waiter: CheckedContinuation<Void, Never>)] = []
    private var returned = 0
    private var returnObservers: [(count: Int, waiter: CheckedContinuation<Void, Never>)] = []

    func enter() async {
        entered += 1
        let ready = observers.filter { $0.count <= entered }
        observers.removeAll { $0.count <= entered }
        for observer in ready { observer.waiter.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitFor(_ count: Int) async {
        if entered < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func leave() {
        returned += 1
        let ready = returnObservers.filter { $0.count <= returned }
        returnObservers.removeAll { $0.count <= returned }
        for observer in ready { observer.waiter.resume() }
    }

    func waitForReturns(_ count: Int) async {
        if returned < count { await withCheckedContinuation { returnObservers.append((count, $0)) } }
    }
}
