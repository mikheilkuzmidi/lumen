import Foundation
import LumenCore
import Testing
@testable import lumen

struct CostTests {
    @Test func editTraceAndConsoleRetainCharges() async throws {
        let lines = LineRecorder()
        let result = await EditRunner.run(host: try ScriptedPhoto(), instruction: "Blue", options: try PhotoFixtures.options(),
                                         models: PhotoFixtures.models(planner: CostPlanner()), line: lines.append)
        #expect(result.totalCost == 0.02)
        #expect(result.modelCalls == 2)
        #expect(lines.lines.last == "Cost: $0.0200 USD · 2 model calls")
        let decoded = try JSONDecoder().decode(EditTrace.self, from: JSONEncoder().encode(result))
        #expect(decoded.totalCost == result.totalCost)
    }

    @Test func evaluationAndBatchReportsShowTotals() throws {
        let event = TraceEvent(kind: .plan, model: "planner", detail: "Plan", started: Date(), duration: 1, cost: 0.025)
        var trace = EditTrace(instruction: "Blue", backend: .meta, modelIDs: ModelIDs(planner: "planner", segmenter: "sam", generator: "image"))
        trace.events = [event]
        let item = EvaluationCase(name: "photo", photo: URL(fileURLWithPath: "/photo.png"), instruction: "Blue")
        let evaluation = EvaluationRunner.markdown([(item, trace), (item, trace)])
        #expect(evaluation.contains("| Model calls | Cost |"))
        #expect(evaluation.contains("| 1 | $0.0250 |"))
        #expect(evaluation.contains("Total cost: $0.0500 USD."))
        let summary = BatchSummary(photos: [BatchPhotoResult(photo: PhotoID("one")), BatchPhotoResult(photo: PhotoID("two"))],
                                   answers: [], modelCalls: 1, duration: 1, events: [event])
        let batch = BatchReport.markdown(summary)
        #expect(batch.contains("Total cost: $0.0250 USD; $0.0125 per photo"))
        var lines = BatchEventLines(photos: [])
        #expect(lines.accept(.finished(summary)).last?.contains("$0.0250 USD") == true)
    }

    @Test func evaluationPrintsAnEndingTotalEvenForUnreadablePhotos() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let lines = LineRecorder()
        let cases = [EvaluationCase(name: "missing", photo: folder.appendingPathComponent("missing.png"), instruction: "Blue")]
        _ = try await EvaluationRunner.run(cases, file: folder.appendingPathComponent("cases.json"), folder: folder.appendingPathComponent("out"),
                                           options: PhotoFixtures.options(), models: PhotoFixtures.models(), line: lines.append)
        #expect(lines.lines.contains("Cost: $0.0000 USD · 0 model calls"))
        #expect(lines.lines.last == "Total cost: $0.0000 USD")
    }
}

private struct CostPlanner: Planner {
    let modelID = "planner"
    func plan(_ request: PlanRequest) async throws -> EditPlan {
        ModelUsageReporting.report?(ModelUsage(cost: 0.01))
        return EditPlan(summary: "Blue", steps: [])
    }
    func critique(_ request: CritiqueRequest) async throws -> Critique {
        ModelUsageReporting.report?(ModelUsage(cost: 0.01))
        return Critique(satisfied: true, notes: "Done")
    }
}
