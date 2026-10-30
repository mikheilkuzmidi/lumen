import Testing
@testable import LumenCore

@Suite("Batch lifecycle", .timeLimit(.minutes(1)))
struct BatchAgentLifecycleTests {
    @Test func openingOnePhotoCanFailWithoutLosingItsEditEvents() async throws {
        let bad = PhotoID("photo-0")
        let good = PhotoID("photo-1")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()], failingEditHost: [bad])
        let events = try await batchTestCollect(await batchTestAgent(library).run(
            BatchOptions(mode: .autonomous, instruction: "Warm the photo", auto: false, straighten: false, concurrency: 1)))
        #expect(events.batchEdits == [bad, good])
        let finished = events.compactMap { if case .editFinished(let result) = $0 { result } else { nil } }
        #expect(finished.map(\.photo) == [bad, good])
        #expect(finished[0].failed)
        #expect(finished[0].instruction == "Warm the photo")
        #expect(await library.saved == [good])
    }

    @Test func eachGroupCanEditTheSamePhotoAndThePlannerDecidesWhichPhotosMatch() async throws {
        let photo = PhotoID("photo-0")
        let bad = PhotoID("photo-1")
        let other = PhotoID("photo-2")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(), batchTestFacts()])
        let plan = BatchPlan(summary: "Warm the photo and add contrast", groups: [
            BatchGroup(id: "warm", title: "Warm", photos: [photo, photo, bad, other, PhotoID("unknown")], instruction: "Warm the photo"),
            BatchGroup(id: "contrast", title: "Contrast", photos: [photo], instruction: "Add contrast"),
        ])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(bad, misfire: true), batchTestReview(other, matches: false)], plans: [plan])
        let planner = BatchTestPlanner()
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer, planner: planner).run(
            BatchOptions(mode: .autonomous, instruction: "Warm the photo and add contrast", auto: false, straighten: false)))
        // Misfires, unknown ids and repeats are dropped; a photo the reviewer did not match is edited when the
        // planner, which sees the whole library, includes it.
        #expect(events.batchEdits.map(\.rawValue).sorted() == ["photo-0", "photo-0", "photo-2"])
        #expect(await planner.plans.map(\.instruction).sorted() == ["Add contrast", "Warm the photo", "Warm the photo"])
        #expect(Set(await library.saved) == [photo, other])
        #expect(try batchTestSummary(events).modelCalls == 8)
        #expect(events.batchProgress == [1, 2, 3])
    }

    @Test func incompleteOrDuplicateReviewsFailOnlyTheirOwnPhotos() async throws {
        let first = PhotoID("photo-0")
        let second = PhotoID("photo-1")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(), batchTestFacts()])
        let reviewer = BatchTestReviewer(reviewResponse: [batchTestReview(first), batchTestReview(first), batchTestReview(second)])
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer).run(BatchOptions(straighten: false)))
        #expect(await library.autos == [second])
        #expect(await library.saved == [second])
        #expect(try batchTestSummary(events).photos.map(\.failed) == [true, false, true])
    }

    @Test func aFailedReviewLeavesItsPhotosJudgedByMeasurement() async throws {
        // The third is a shaken frame: fine detail enough as a whole, sharp nowhere.
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(sharpness: 0.01), batchTestFacts(sharpness: 0.08, peakSharpness: 0.03)])
        let reviewer = BatchTestReviewer(reviewError: LumenError.timedOut)
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer).run(BatchOptions(straighten: false)))
        let summary = try batchTestSummary(events)
        #expect(summary.photos.map(\.failed) == [false, false, false])
        #expect(summary.photos[1].flagged == "Almost no fine detail was measured.")
        #expect(summary.photos[2].flagged == "No part of the photo is sharp.")
        #expect(await library.autos == [PhotoID("photo-0")])
        #expect(await library.saved == [PhotoID("photo-0")])
        #expect(summary.photos.allSatisfy { ($0.outcome ?? "").contains("The library review failed") })
    }

    @Test func aFinishedAgentCanRunAnotherBatchImmediately() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let agent = batchTestAgent(library)
        let options = BatchOptions(mode: .autonomous, auto: false, straighten: false)
        let first = try batchTestSummary(try await batchTestCollect(await agent.run(options)))
        let second = try batchTestSummary(try await batchTestCollect(await agent.run(options)))
        #expect(first.photos == second.photos)
        #expect(await library.measured.count == 2)
        #expect(second.modelCalls == 0)
        #expect(second.answers.isEmpty)
    }

    @Test func endingTheConsumerCancelsItsPhotoAgent() async throws {
        let gate = BatchTestGate()
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let planner = BatchTestPlanner(gate: gate)
        let agent = batchTestAgent(library, planner: planner)
        let consumer = Task { try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Warm the photo", auto: false,
                                                                                    straighten: false, concurrency: 1))) }
        await gate.waitFor(1)
        consumer.cancel()
        _ = try? await consumer.value
        await gate.release()
        await gate.waitForReturns(1)
        #expect(await planner.cancellations == 1)
        #expect(await library.edited.count == 1)
        #expect(await library.saved.isEmpty)
    }

    @Test func cancellationDuringMeasurementNeverReachesTheBasePass() async throws {
        let gate = BatchTestGate()
        let library = BatchTestLibrary(Array(repeating: batchTestFacts(), count: 10), factsGate: gate)
        let agent = batchTestAgent(library)
        let consumer = Task { try await batchTestCollect(await agent.run(BatchOptions(straighten: false, concurrency: 2))) }
        await gate.waitFor(2)
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("A cancelled measurement must fail the stream.")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await library.measured.count == 2)
        #expect(await library.autos.isEmpty)
        #expect(await library.saved.isEmpty)
    }
}
