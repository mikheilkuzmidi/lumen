import Foundation
import LumenCore
@testable import lumen

actor BatchScriptedInput {
    private var lines: [String]
    private(set) var reads = 0

    init(_ lines: [String]) { self.lines = lines }
    func read() -> String? {
        reads += 1
        return lines.isEmpty ? nil : lines.removeFirst()
    }
    nonisolated func input(terminal: Bool = true) -> BatchInput {
        BatchInput(isTerminal: terminal, read: { await self.read() })
    }
}

actor BatchScriptedLibrary: LibraryHost {
    let output: URL
    let ordered: [PhotoID]
    private let image: EncodedImage
    private let improved: EncodedImage
    private var changed: Set<PhotoID> = []
    private var documents: [PhotoID: ScriptedPhoto] = [:]
    private var flags: [PhotoID: String] = [:]
    private let failToList: Bool
    private(set) var saved: [PhotoID] = []
    private(set) var auto: [PhotoID] = []
    private(set) var angles: [PhotoID: Double] = [:]

    init(output: URL, names: [String] = ["good.png", "tilted.png", "misfire.png", "low.png"], failToList: Bool = false) throws {
        self.output = output
        self.failToList = failToList
        ordered = names.map(PhotoID.init)
        image = try PhotoFixtures.image(gray: 0.2)
        improved = try PhotoFixtures.image(gray: 0.8)
    }

    func photos() async throws -> [PhotoID] {
        if failToList { throw CLIError("Could not list the library.") }
        return ordered
    }
    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage {
        changed.contains(photo) ? improved : image
    }
    func facts(_ photo: PhotoID) async throws -> PhotoFacts {
        if photo.rawValue == "broken.png" { throw CLIError("Unreadable photo.") }
        // The tilted photo's walls lean with its horizon: its camera was rolled.
        let tilt: Double? = photo.rawValue == "tilted.png" ? 2 : nil
        return PhotoFacts(size: image.size, sharpness: 0.8, exposure: 0.5, tilt: tilt, verticalLean: tilt)
    }
    func applyAuto(_ photo: PhotoID) async throws -> String {
        auto.append(photo)
        changed.insert(photo)
        return "Auto: exposure +0.3"
    }
    func straighten(_ photo: PhotoID, degrees: Double) async throws { angles[photo] = degrees }
    func flag(_ photo: PhotoID, reason: String) async throws { flags[photo] = reason }
    func editHost(_ photo: PhotoID) async throws -> any EditHost {
        if let document = documents[photo] { return document }
        let document = try ScriptedPhoto()
        documents[photo] = document
        return document
    }
    func save(_ photo: PhotoID) async throws {
        if photo.rawValue == "save-fails.png" { throw CLIError("Could not save photo.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let destination = output.appendingPathComponent(photo.rawValue)
        try (changed.contains(photo) ? improved : image).data.write(to: destination)
        let labels = await documents[photo]?.layers.map(\.label) ?? []
        let sidecar = Sidecar(layers: labels, straighteningAngle: angles[photo] ?? 0, flag: flags[photo])
        try JSONEncoder().encode(sidecar).write(to: destination.appendingPathExtension("lumen.json"))
        saved.append(photo)
    }

    private struct Sidecar: Encodable {
        var layers: [String]
        var straighteningAngle: Double
        var flag: String?
    }
}

actor BatchPause {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        entered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        try await Task.sleep(for: .seconds(60))
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
}

struct BatchWaitingReviewer: BatchPlanner {
    let modelID = "muse-spark-1.3"
    let pause: BatchPause

    func review(_ request: ReviewRequest) async throws -> [PhotoReview] {
        try await pause.wait()
        return []
    }
    func plan(_ request: BatchPlanRequest) async throws -> BatchPlan {
        throw CLIError("The cancelled review must not reach planning.")
    }
}

actor BatchScriptedReviewer: BatchPlanner {
    let modelID = "muse-spark-1.3"
    let question: BatchQuestion?
    private(set) var requests: [BatchPlanRequest] = []

    init(question: BatchQuestion? = nil) { self.question = question }
    func review(_ request: ReviewRequest) async throws -> [PhotoReview] {
        request.photos.map {
            PhotoReview(photo: $0.photo, misfire: $0.photo.rawValue == "misfire.png", misfireReason: "Pocket shot",
                        quality: $0.photo.rawValue == "low.png" ? 0.3 : 0.8, description: "Friends on a walk",
                        group: "hikers", matchesInstruction: request.instruction != nil)
        }
    }
    func plan(_ request: BatchPlanRequest) async throws -> BatchPlan {
        requests.append(request)
        let instruction = request.answers["style"] == "Green coats" ? "Make the coat green" : "Make the coat navy"
        return BatchPlan(summary: "Change the coats.", groups: [
            BatchGroup(id: "hikers", title: "Hikers", photos: request.reviews.map(\.photo), instruction: instruction),
        ], questions: question.map { request.answers[$0.id] == nil ? [$0] : [] } ?? [])
    }

    static let style = BatchQuestion(id: "style", question: "Which coat colour?", options: ["Navy coats", "Green coats"],
                                     recommended: 0, groups: ["hikers"])
}
