import Foundation
import LumenCore

enum BatchRunner {
    static func run(host: any LibraryHost, reviewer: any BatchPlanner, models: EditModels, options: BatchOptions,
                    output: URL, answers: [String: String] = [:], approve: Bool = false,
                    input: BatchInput, line: @Sendable (String) -> Void) async throws -> BatchSummary {
        try Task.checkCancellation()
        let photos = try await host.photos()
        let library = BatchLibrary(base: host)
        let agent = BatchAgent(host: library, reviewer: reviewer, planner: models.planner,
                               segmenter: models.segmenter, generator: models.generator)
        var choices: [String: BatchChoice] = [:]
        var lines = BatchEventLines(photos: photos)
        var summary: BatchSummary?
        var runOptions = options
        // Route automatic choices through the console so answer files and recorded authors agree.
        if options.mode == .autonomous { runOptions.mode = .askWhenUnsure }
        do {
            return try await withTaskCancellationHandler {
                for try await event in await agent.run(runOptions) {
                    try Task.checkCancellation()
                    switch event {
                    case .question(let question):
                        let choice = try await input.choose(question, supplied: answers,
                                                            autonomous: options.mode == .autonomous, line: line)
                        choices[question.id] = choice
                        await agent.answer(question.id, with: choice.text)
                    case .answered(var answer):
                        if let choice = choices[answer.question.id] { answer.byPerson = choice.byPerson }
                        for text in lines.accept(.answered(answer)) { line(text) }
                    case .awaitingApproval(let plan, let estimate):
                        line("Estimate: About \(estimate) more model calls" + (plan.estimatedCost.map { ", about " + dollars($0, estimated: true) + " USD" } ?? "") + "; actual cost and calls depend on each edit.")
                        if !approve {
                            let accepted = try await input.approve(line: line)
                            if !accepted {
                                line("Plan declined. No photo changes were made.")
                                throw LumenError.cancelled
                            }
                        }
                        await agent.approve()
                    case .finished(var result):
                        for index in result.answers.indices {
                            if let choice = choices[result.answers[index].question.id] {
                                result.answers[index].byPerson = choice.byPerson
                            }
                        }
                        summary = result
                    default:
                        for text in lines.accept(event) { line(text) }
                    }
                }
                try Task.checkCancellation()
                guard var result = summary else { throw CLIError("The batch stopped without a summary.") }
                // The agent saves changes; the command also exports unchanged photos and persists flags.
                for index in result.photos.indices {
                    try Task.checkCancellation()
                    do { try await library.saveIfNeeded(result.photos[index].photo) }
                    catch {
                        if Task.isCancelled || error is CancellationError { throw LumenError.cancelled }
                        result.photos[index].failed = true
                        let previous = result.photos[index].outcome.map { $0 + "\n" } ?? ""
                        result.photos[index].outcome = previous + error.localizedDescription
                    }
                }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try BatchReport.write(result, choices: choices, to: output)
                let kept = result.photos.filter { $0.flagged == nil }.map(\.photo)
                try await BatchContactSheet.write(kept, to: output.appendingPathComponent("contact-before.jpg")) { photo in
                    await library.original(photo)
                }
                try await BatchContactSheet.write(kept, to: output.appendingPathComponent("contact-after.jpg")) { photo in
                    try? await host.thumbnail(photo, maxLongEdge: BatchContactSheet.photoEdge)
                }
                try Task.checkCancellation()
                for photo in result.photos where photo.failed {
                    line("\(oneLine(photo.photo.rawValue)): Failed: \(oneLine(photo.outcome ?? "Could not edit this photo."))")
                }
                for text in lines.accept(.finished(result)) { line(text) }
                return result
            } onCancel: { Task { await agent.cancel() } }
        } catch {
            await agent.cancel()
            if Task.isCancelled || error is CancellationError { throw LumenError.cancelled }
            throw error
        }
    }
}

/// Keeps small originals for contact sheets and avoids exporting a photo twice.
private actor BatchLibrary: LibraryHost {
    let base: any LibraryHost
    private var originals: [PhotoID: EncodedImage] = [:]
    private var saveAttempts: Set<PhotoID> = []

    init(base: any LibraryHost) { self.base = base }

    func photos() async throws -> [PhotoID] { try await base.photos() }
    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage {
        try await base.thumbnail(photo, maxLongEdge: maxLongEdge)
    }
    func facts(_ photo: PhotoID) async throws -> PhotoFacts {
        let facts = try await base.facts(photo)
        originals[photo] = try await base.thumbnail(photo, maxLongEdge: BatchContactSheet.photoEdge)
        return facts
    }
    func applyAuto(_ photo: PhotoID) async throws -> String { try await base.applyAuto(photo) }
    func straighten(_ photo: PhotoID, degrees: Double) async throws { try await base.straighten(photo, degrees: degrees) }
    func flag(_ photo: PhotoID, reason: String) async throws { try await base.flag(photo, reason: reason) }
    func editHost(_ photo: PhotoID) async throws -> any EditHost { try await base.editHost(photo) }
    func save(_ photo: PhotoID) async throws {
        saveAttempts.insert(photo)
        try await base.save(photo)
    }
    func saveIfNeeded(_ photo: PhotoID) async throws {
        if !saveAttempts.contains(photo) { try await save(photo) }
    }
    func original(_ photo: PhotoID) -> EncodedImage? { originals[photo] }
}
