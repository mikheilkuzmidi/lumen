import Foundation
import LumenCore
import LumenMeta
import LumenRender
import Testing

/// Runs a real edit with the Meta models on a fixture. Paid; runs only with LUMEN_LIVE=1 and META_API_KEY set.
/// The result, the before/after and the event log go to $TMPDIR/lumen-live.
@Suite("Live edit", .enabled(if: ProcessInfo.processInfo.environment["LUMEN_LIVE"] == "1"))
struct LiveEditTests {
    @Test func editsAFixtureWithTheMetaModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        let name = environment["LUMEN_LIVE_PHOTO"] ?? "jacket-with-a-hood.jpg"
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("instructions.json")))
        let instruction = environment["LUMEN_LIVE_INSTRUCTION"] ?? cases.cases.first { $0.photo.hasSuffix(name) }?.instruction ?? "Make it warmer."
        let configuration = try MetaConfiguration.fromEnvironment()
        let document = try PhotoDocument(contentsOf: Self.fixtures.appendingPathComponent("photos/\(name)"))
        let agent = EditAgent(planner: MetaPlanner(configuration: configuration), segmenter: MetaSegmenter(configuration: configuration),
                              generator: MetaGenerator(configuration: configuration), host: document,
                              configuration: AgentConfiguration(maxSteps: 10, maxRevisions: 1))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-live", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = ["Instruction: \(instruction)"]
        var applied = 0, finished = false
        for try await event in agent.run(instruction) {
            switch event {
            case .planned(let plan): log.append("Plan: \(plan.summary) — \(plan.steps.map(\.type).joined(separator: ", "))")
            case .stepStarted(let index, let step): log.append("Step \(index + 1): \(step.type)")
            case .selected(let region, let segment): log.append(String(format: "Selected %@: %.1f%% of the photo", region, segment.mask.area * 100))
            case .applied(let layer): applied += 1; log.append("Layer: \(layer.label)")
            case .critiqued(let critique): log.append("Critique: \(critique.satisfied ? "satisfied" : "not yet") — \(critique.notes)")
            case .finished(let reason): finished = true; log.append("Finished: \(reason)")
            case .trace(let trace): log.append(String(format: "  [%@%@] %.1f s %@", trace.kind.rawValue, trace.model.map { " " + $0 } ?? "", trace.duration, trace.detail))
            }
        }
        let stem = (name as NSString).deletingPathExtension
        try await document.export(to: out.appendingPathComponent("\(stem)-lumen.jpg"), format: .jpeg)
        try log.joined(separator: "\n").write(to: out.appendingPathComponent("\(stem).log"), atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
        #expect(finished && applied > 0)
    }

    private struct Cases: Decodable {
        struct Case: Decodable { var photo: String; var instruction: String }
        var cases: [Case]
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
}
