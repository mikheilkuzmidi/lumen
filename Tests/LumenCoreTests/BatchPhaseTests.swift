import Foundation
import Testing
@testable import LumenCore

@Suite("Batch provider progress", .timeLimit(.minutes(1)))
struct BatchPhaseTests {
    @Test func sharedProviderPhasesArriveWhileTheirResponsesAreStillBlocked() async throws {
        let photo = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts()])
        let reviewing = BatchTestGate(), planning = BatchTestGate()
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(photo)], plans: [
            BatchPlan(summary: "Make shirt blue", groups: [
                BatchGroup(id: "shirt", title: "Shirt", photos: [photo], instruction: "Make the shirt blue"),
            ])
        ], gate: reviewing, planGate: planning)
        let agent = batchTestAgent(library, reviewer: reviewer)
        let observed = BatchPhaseObservation()
        let stream = await agent.run(BatchOptions(mode: .planFirst, instruction: "Make the shirt blue", auto: false,
                                                 straighten: false, flagMisfires: false, qualityThreshold: 0))
        let consumer = Task {
            for try await event in stream {
                await observed.receive(event)
                if case .awaitingApproval(let plan, _) = event {
                    _ = try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken)))
                }
            }
        }
        await reviewing.waitFor(1)
        await observed.waitForPhases(1)
        #expect(await observed.phases == [.reviewing(count: 1, model: reviewer.modelID)])
        #expect(await observed.completedSharedCalls == 0)
        #expect(await library.edited.isEmpty)
        await reviewing.release()

        await planning.waitFor(1)
        await observed.waitForPhases(2)
        #expect(await observed.phases == [.reviewing(count: 1, model: reviewer.modelID), .planning(model: reviewer.planModelID)])
        #expect(await observed.completedSharedCalls == 1)
        #expect(await library.edited.isEmpty)
        await planning.release()
        try await consumer.value
        #expect(await observed.completedSharedCalls == 2, "Start events must not duplicate completion traces or costs")
    }
}

private actor BatchPhaseObservation {
    private(set) var phases: [BatchPhase] = []
    private(set) var completedSharedCalls = 0

    func receive(_ event: BatchEvent) {
        switch event {
        case .phase(let phase): phases.append(phase)
        case .trace(let trace) where trace.model != nil: completedSharedCalls += 1
        default: break
        }
    }

    func waitForPhases(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while phases.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
