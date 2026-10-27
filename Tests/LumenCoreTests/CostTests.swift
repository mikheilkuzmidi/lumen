import Foundation
import Testing
@testable import LumenCore

struct CostTests {
    @Test func oldTracesAndSummariesDecodeWithoutCost() throws {
        let trace = TraceEvent(kind: .plan, model: "planner", detail: "Plan", started: Date(), duration: 1)
        let decoded = try JSONDecoder().decode(TraceEvent.self, from: JSONEncoder().encode(trace))
        #expect(decoded.cost == nil)
        #expect(decoded.inputTokens == nil)
        let summary = try JSONDecoder().decode(BatchSummary.self, from: Data(#"{"photos":[],"answers":[],"modelCalls":0,"duration":0}"#.utf8))
        #expect(summary.totalCost == 0)
        #expect(summary.costPerPhoto == 0)
    }

    @Test func batchTotalsIncludeSharedCallsAndKeepEditAverageSeparate() {
        let photos = [BatchPhotoResult(photo: PhotoID("one"), instruction: "Blue", cost: 0.04),
                      BatchPhotoResult(photo: PhotoID("two"), instruction: "Blue", cost: 0.06),
                      BatchPhotoResult(photo: PhotoID("three"), failed: true, cost: 0.5)]
        let summary = BatchSummary(photos: photos, answers: [], modelCalls: 4, duration: 1, events: [
            TraceEvent(kind: .plan, model: "planner", detail: "Library", started: Date(), duration: 0, cost: 0.02),
            TraceEvent(kind: .critique, model: "planner", detail: "Photo", started: Date(), duration: 0, cost: 0.6),
        ])
        #expect(summary.totalCost == 0.62)
        #expect(abs(summary.costPerPhoto - 0.62 / 3) < 0.00000001)
        #expect(summary.estimatedCost(for: 10, defaultCostPerPhoto: 0.031) == 0.5)
        let empty = BatchSummary(photos: [], answers: [], modelCalls: 0, duration: 0)
        #expect(empty.estimatedCost(for: 1_000, defaultCostPerPhoto: 0.031) == 31)
        #expect(empty.estimatedCost(for: 0, defaultCostPerPhoto: 0.031) == 0)
    }

    @Test func concurrentBatchCallsKeepEachPhotosUsage() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(), batchTestFacts()])
        let agent = BatchAgent(host: library, reviewer: PricedReviewer(), planner: PricedPlanner(), segmenter: BatchTestSegmenter(), generator: BatchTestGenerator())
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Blue", concurrency: 3)))
        let summary = try batchTestSummary(events)
        #expect(summary.modelCalls == 8)
        #expect(abs(summary.totalCost - 0.075) < 0.00000001)
        #expect(summary.photos.allSatisfy { $0.cost == 0.02 })
        #expect(summary.events == events.batchTraces)
        #expect(summary.events?.filter { $0.inputTokens == 3_000 }.count == 6)
    }

    @Test func approvalCarriesTheDefaultEstimateWithoutChangingItsEventSignature() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let agent = BatchAgent(host: library, reviewer: nil, planner: PricedPlanner(), segmenter: BatchTestSegmenter(), generator: BatchTestGenerator())
        var approved = false
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Blue")) {
            if case .awaitingApproval(let plan, let calls) = event {
                #expect(calls == 10)
                #expect(plan.estimatedCost == 0.062)
                #expect(await library.autos.isEmpty)
                approved = true
                await agent.approve()
            }
        }
        #expect(approved)
    }
}

private struct PricedPlanner: Planner, PhotoCostEstimating {
    let modelID = "priced-planner"
    let estimatedCostPerPhoto = 0.031
    func plan(_ request: PlanRequest) async throws -> EditPlan {
        await Task.yield()
        ModelUsageReporting.report?(ModelUsage(cost: 0.01, inputTokens: 3_000, cachedInputTokens: 0, outputTokens: 1_000))
        return EditPlan(summary: "Blue", steps: [.adjust(Adjustment(values: [.temperature: 10]))])
    }
    func critique(_ request: CritiqueRequest) async throws -> Critique {
        await Task.yield()
        ModelUsageReporting.report?(ModelUsage(cost: 0.01, inputTokens: 3_000, cachedInputTokens: 0, outputTokens: 1_000))
        return Critique(satisfied: true, notes: "Done")
    }
}

private struct PricedReviewer: BatchPlanner {
    let modelID = "priced-reviewer"
    func review(_ request: ReviewRequest) async throws -> [PhotoReview] {
        ModelUsageReporting.report?(ModelUsage(cost: 0.005))
        return request.photos.map { batchTestReview($0.photo) }
    }
    func plan(_ request: BatchPlanRequest) async throws -> BatchPlan {
        ModelUsageReporting.report?(ModelUsage(cost: 0.01))
        return BatchPlan(summary: request.instruction, groups: [
            BatchGroup(id: "people", title: "People", photos: request.reviews.map(\.photo), instruction: request.instruction),
        ])
    }
}
