import Foundation
import Testing
@testable import LumenCore

@Suite("Batch edit outcomes", .timeLimit(.minutes(1)))
struct BatchOutcomeTests {
    @Test func finalCriticRejectionFailsEvenWhenEveryStepSucceeded() async throws {
        let photo = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts()])
        let planner = BatchTestPlanner(revisions: 9)
        let agent = batchTestAgent(library, planner: planner)
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Warm it",
                                                                           auto: false, straighten: false, qualityThreshold: 0)))
        let result = try #require(batchTestSummary(events).photos.first)
        #expect(await planner.critiques.count == 3)
        #expect(!events.batchTraces.contains { $0.kind == .failure }, "This is a rejected result, not a failed step")
        #expect(result.outcome?.contains("Revision limit reached") == true)
        #expect(result.failed)
        let ended = try #require(events.compactMap { if case .editFinished(let value) = $0 { value } else { nil } }.last)
        #expect(ended.failed)
        let snapshot = try #require(await agent.snapshot())
        #expect(snapshot.failedPhotoIDs == [photo])
        #expect(snapshot.completedPhotoIDs.isEmpty)
        #expect(await library.saved == [photo], "Keep partial layers inspectable and reversible")
    }

    @Test func earlierRejectionDoesNotJudgeALaterTrustedSimpleRevision() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let planner = BatchOutcomePlanner(simpleFinish: true)
        let agent = outcomeAgent(library, planner: planner)
        let result = try #require(batchTestSummary(try await batchTestCollect(await agent.run(
            BatchOptions(mode: .autonomous, instruction: "Warm it", auto: false, straighten: false,
                         qualityThreshold: 0)))).photos.first)
        #expect(await planner.critiqueCount == 1)
        #expect(result.outcome == "Applied the revised adjustment.")
        #expect(!result.failed, "The rejected pixels were changed; a previous verdict is not a final verdict")
    }

    @Test func noCritiqueStepLimitKeepsItsExplicitExistingOutcome() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let planner = BatchTestPlanner()
        let agent = BatchAgent(host: library, reviewer: nil, planner: planner, segmenter: BatchTestSegmenter(),
                               generator: BatchTestGenerator(), configuration: AgentConfiguration(maxSteps: 1))
        let result = try #require(batchTestSummary(try await batchTestCollect(await agent.run(
            BatchOptions(mode: .autonomous, instruction: "Warm it", auto: false, straighten: false,
                         qualityThreshold: 0)))).photos.first)
        #expect(await planner.critiques.isEmpty)
        #expect(result.outcome == "Step limit reached.")
        #expect(!result.failed, "An absent verdict must not be invented as a rejection")
    }

    @Test func cancellationWhileCriticWaitsRemainsUnfinishedRatherThanFailed() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let gate = BatchTestGate()
        let agent = outcomeAgent(library, planner: BatchOutcomePlanner(critiqueGate: gate))
        let consumer = Task {
            try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Warm it",
                                                                   auto: false, straighten: false, qualityThreshold: 0)))
        }
        await gate.waitFor(1)
        await agent.cancel()
        await gate.release()
        let stopped = try #require(await agent.cancelAndWait())
        await #expect(throws: LumenError.cancelled) { try await consumer.value }
        #expect(stopped.cancelled && stopped.settled)
        #expect(stopped.failedPhotoIDs.isEmpty && stopped.completedPhotoIDs.isEmpty)
        #expect(stopped.unfinishedPhotoIDs == [PhotoID("photo-0")])
        #expect(await library.saved.isEmpty)
    }
}

private func outcomeAgent(_ library: BatchTestLibrary, planner: BatchOutcomePlanner) -> BatchAgent {
    BatchAgent(host: library, reviewer: nil, planner: planner, segmenter: BatchTestSegmenter(), generator: BatchTestGenerator())
}

private actor BatchOutcomePlanner: Planner {
    let modelID = "muse-spark-1.3"
    let simpleFinish: Bool
    let critiqueGate: BatchTestGate?
    private(set) var critiqueCount = 0

    init(simpleFinish: Bool = false, critiqueGate: BatchTestGate? = nil) {
        self.simpleFinish = simpleFinish; self.critiqueGate = critiqueGate
    }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        EditPlan(summary: "Warm it", steps: [.adjust(Adjustment(values: [.temperature: 8]))])
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiqueCount += 1
        await critiqueGate?.enter()
        try Task.checkCancellation()
        var steps: [EditStep] = [.adjust(Adjustment(values: [.temperature: 4]))]
        if simpleFinish { steps.append(.finish(Finish(reason: "Applied the revised adjustment."))) }
        return Critique(satisfied: false, notes: "A little warmer", steps: steps)
    }
}
