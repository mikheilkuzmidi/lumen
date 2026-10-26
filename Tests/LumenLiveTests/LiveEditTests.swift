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
            case .reverted(let id): log.append("Reverted layer \(id)")
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

    /// Three instructions on one photo: an edit, a follow-up that should reuse its region, and an undo.
    @Test func followsUpOnTheSameEdit() async throws {
        let configuration = try MetaConfiguration.fromEnvironment()
        let document = try PhotoDocument(contentsOf: Self.fixtures.appendingPathComponent("photos/jacket-with-a-hood.jpg"))
        let agent = EditAgent(planner: MetaPlanner(configuration: configuration), segmenter: MetaSegmenter(configuration: configuration),
                              generator: MetaGenerator(configuration: configuration), host: document,
                              configuration: AgentConfiguration(maxSteps: 8, maxRevisions: 1))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-live", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = []
        var turns: [(selections: Int, applied: Int, reverted: Int)] = []
        for (turn, instruction) in ["Make his jacket bright yellow", "A bit less yellow", "Undo that"].enumerated() {
            log.append("Instruction: \(instruction)")
            var selections = 0, applied = 0, reverted = 0
            for try await event in agent.run(instruction) {
                switch event {
                case .planned(let plan): log.append("Plan: \(plan.summary) — \(plan.steps.map(\.type).joined(separator: ", "))")
                case .selected(let region, _): selections += 1; log.append("Selected \(region)")
                case .applied(let layer): applied += 1; log.append("Layer: \(layer.label)")
                case .reverted(let id): reverted += 1; log.append("Reverted layer \(id)")
                case .critiqued(let critique): log.append("Critique: \(critique.satisfied ? "satisfied" : "not yet") — \(critique.notes)")
                case .finished(let reason): log.append("Finished: \(reason)")
                case .trace(let trace) where trace.model != nil:
                    log.append(String(format: "  [%@ %@] %.1f s", trace.kind.rawValue, trace.model ?? "", trace.duration))
                default: break
                }
            }
            turns.append((selections, applied, reverted))
            try await document.export(to: out.appendingPathComponent("follow-up-\(turn + 1).jpg"), format: .jpeg)
        }
        try log.joined(separator: "\n").write(to: out.appendingPathComponent("follow-up.log"), atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
        #expect(turns[0].applied > 0, "the first instruction changes the photo")
        #expect(turns[1].selections == 0 && turns[1].applied > 0, "the follow-up reuses the jacket without selecting it again")
        #expect(turns[2].reverted > 0, "the undo takes a layer off")
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
}
