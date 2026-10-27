import Foundation
import LumenCore
import Synchronization
import Testing
@testable import LumenMeta

struct CostTests {
    @Test func cachedInputAndReasoningUsePublishedPrices() async throws {
        let usage = Mutex<ModelUsage?>(nil)
        let planner = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([
            try pricedReply(file: "plan.json", input: 3_000, cached: 2_000, output: 1_000),
        ]))
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await planner.plan(PlanRequest(instruction: "Darken the sky", image: testPhoto))
        }
        let measured = try #require(usage.withLock { $0 })
        #expect(measured.inputTokens == 3_000)
        #expect(measured.cachedInputTokens == 2_000)
        #expect(measured.outputTokens == 1_000)
        #expect(abs(try #require(measured.cost) - 0.0058) < 0.00000001)
        #expect(MetaPricing.cost(model: "muse-wonder-1.0", inputTokens: 3_000, cachedInputTokens: 2_000, outputTokens: 1_000) == 0.0244)
        #expect(MetaPricing.date == "2026-10-26")
        #expect(abs(MetaPricing.defaultPhotoCost - 0.031) < 0.00000001)
    }

    @Test func unknownModelRetainsUsageWithoutInventingAPrice() async throws {
        var configuration = testConfiguration
        configuration.planningModel = "another-model"
        let usage = Mutex<ModelUsage?>(nil)
        let planner = MetaPlanner(configuration: configuration, transport: ReplayTransport([
            try pricedReply(file: "plan.json", input: 40, cached: 0, output: 60),
        ]))
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto))
        }
        let measured = try #require(usage.withLock { $0 })
        #expect(measured == ModelUsage(inputTokens: 40, cachedInputTokens: 0, outputTokens: 60))
    }

    @Test func refusedAndUnusableAnswersRetainBilledUsage() async throws {
        for file in ["refusal.json", "malformed.json"] {
            let usage = Mutex<ModelUsage?>(nil)
            let planner = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([
                try pricedReply(file: file, input: 3_000, output: 1_000),
            ]))
            await #expect(throws: LumenError.self) {
                try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
                    try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto))
                }
            }
            #expect(usage.withLock { $0?.cost } == 0.008)
        }
    }

    @Test func segmentationAndReturnedImagesHaveFlatCharges() async throws {
        let usage = Mutex<ModelUsage?>(nil)
        let segmenter = MetaSegmenter(configuration: testConfiguration, transport: ReplayTransport([try .init(file: "sam.sse")]))
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await segmenter.segment(SegmentRequest(image: testPhoto, concept: "coat"))
        }
        #expect(usage.withLock { $0?.cost } == 0.0025)
        let photo = try recordedPhoto()
        var reply = try ReplayTransport.Reply(file: "image.json")
        var answer = try json(reply.body)
        answer["usage"] = ["input_tokens": 9_831, "output_tokens": 749, "total_tokens": 10_580]
        reply.body = try JSONSerialization.data(withJSONObject: answer)
        let generator = MetaGenerator(configuration: testConfiguration, transport: ReplayTransport([reply]))
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await generator.generate(GenerateRequest(image: photo, mask: MaskData(size: photo.size, filledWith: 255), prompt: "Navy"))
        }
        #expect(usage.withLock { $0?.cost } == 0.01)
        #expect(usage.withLock { $0?.inputTokens } == 9_831)
        #expect(usage.withLock { $0?.outputTokens } == 749)
    }

    @Test func failedGenerationsHaveZeroCharge() async throws {
        let photo = try recordedPhoto()
        for reply in [ReplayTransport.Reply(text: #"{"data":[]}"#), .init(text: #"{"data":[{"b64_json":"AQID"}]}"#),
                      .init(status: 402), .init(failure: .timedOut)] {
            let usage = Mutex<ModelUsage?>(nil)
            let generator = MetaGenerator(configuration: testConfiguration, transport: ReplayTransport([reply]))
            await #expect(throws: LumenError.self) {
                try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
                    try await generator.generate(GenerateRequest(image: photo, mask: MaskData(size: photo.size, filledWith: 255), prompt: "Navy"))
                }
            }
            #expect(usage.withLock { $0?.cost } == 0)
        }
    }

    @Test func batchReviewAndWonderPlanningReportTheirOwnPrices() async throws {
        let usage = Mutex<ModelUsage?>(nil)
        let reviewer = MetaBatchPlanner(configuration: testConfiguration, transport: ReplayTransport([
            try pricedReply(file: "batch-review.json", input: 3_000, cached: 2_000, output: 1_000),
            try pricedReply(file: "batch-plan-answered.json", input: 3_000, cached: 2_000, output: 1_000),
        ]))
        let reviews = (1...3).map { PhotoReview(photo: PhotoID("\($0)"), misfire: false, quality: 1, description: "shirt", group: "people", matchesInstruction: true) }
        let photo = try recordedPhoto()
        let inputs = reviews.map { ReviewPhoto(photo: $0.photo, thumbnail: photo, facts: PhotoFacts(size: photo.size, sharpness: 0.8, exposure: 0.5)) }
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await reviewer.review(ReviewRequest(instruction: "Blue shirts", photos: inputs))
        }
        #expect(usage.withLock { $0?.cost } == 0.0058)
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await reviewer.plan(BatchPlanRequest(instruction: "Blue shirts", reviews: reviews))
        }
        #expect(usage.withLock { $0?.cost } == 0.0244)
    }

    @Test func emptySegmentationStillCostsOneImage() async throws {
        let usage = Mutex<ModelUsage?>(nil)
        let answer = try sse([laneEvent("response.output_text.done", ["text": ""]),
                              ["type": "response.completed", "response": ["status": "completed"]]])
        let segmenter = MetaSegmenter(configuration: testConfiguration, transport: ReplayTransport([.init(text: answer)]))
        let segments = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await segmenter.segment(SegmentRequest(image: testPhoto, concept: "coat"))
        }
        #expect(segments.isEmpty)
        #expect(usage.withLock { $0?.cost } == 0.0025)
    }

    @Test func missingUsageIsUnpricedAndMissingCacheDetailsMeanNoCache() async throws {
        let usage = Mutex<ModelUsage?>(nil)
        var reply = try pricedReply(file: "plan.json", input: 3_000, output: 1_000)
        var answer = try json(reply.body)
        answer["usage"] = ["prompt_tokens": 3_000, "completion_tokens": 1_000]
        reply.body = try JSONSerialization.data(withJSONObject: answer)
        let planner = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([reply, try .init(file: "plan.json")]))
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto))
        }
        #expect(usage.withLock { $0?.cost } == 0.008)
        #expect(usage.withLock { $0?.cachedInputTokens } == 0)
        usage.withLock { $0 = nil }
        _ = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
            try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto))
        }
        #expect(usage.withLock { $0 } == nil)
    }

    @Test func agentAttachesUsageToEachRecordedCall() async throws {
        let planner = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([
            try pricedReply(file: "plan.json", input: 3_000, cached: 2_000, output: 1_000),
            try pricedReply(file: "critique.json", input: 3_000, output: 1_000),
        ]))
        let agent = EditAgent(planner: planner,
                              segmenter: MetaSegmenter(configuration: testConfiguration, transport: ReplayTransport([try .init(file: "sam.sse")])),
                              generator: MetaGenerator(configuration: testConfiguration, transport: ReplayTransport([])), host: CostPhoto())
        var traces: [TraceEvent] = []
        for try await event in agent.run("Darken the sky") {
            if case .trace(let trace) = event { traces.append(trace) }
        }
        #expect(traces.filter { $0.model != nil }.count == 3)
        #expect(traces.map(\.cost) == [0.0058, 0.0025, 0.008, nil])
        #expect(traces.first?.outputTokens == 1_000)
    }
}

private func pricedReply(file: String, input: Int, cached: Int = 0, output: Int) throws -> ReplayTransport.Reply {
    var reply = try ReplayTransport.Reply(file: file)
    var answer = try json(reply.body)
    answer["usage"] = ["prompt_tokens": input, "completion_tokens": output,
                       "prompt_tokens_details": ["cached_tokens": cached],
                       "completion_tokens_details": ["reasoning_tokens": min(output, 800)]]
    reply.body = try JSONSerialization.data(withJSONObject: answer)
    return reply
}

private actor CostPhoto: EditHost {
    func size() -> PixelSize { testPhoto.size }
    func render(maxLongEdge: Int) -> EncodedImage { testPhoto }
    func render(region: NormalizedRect, maxLongEdge: Int) -> EncodedImage { testPhoto }
    func apply(_ layer: Layer, assets: AssetStore) {}
    func remove(_ layer: Layer.ID) {}
}
