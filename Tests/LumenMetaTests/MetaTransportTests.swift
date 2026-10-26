import Foundation
import LumenCore
import Testing
@testable import LumenMeta

@Test func mapsHTTPFailuresForEveryModel() async throws {
    let photo = try recordedPhoto()
    for (status, headers, expected) in [
        (401, [:], LumenError.http(status: 401, message: "Check your Meta API key and its model access.")),
        (403, [:], .http(status: 403, message: "Check your Meta API key and its model access.")),
        (402, [:], .paymentRequired),
        (429, ["retry-after": "12"], .rateLimited(retryAfter: 12)),
        (429, ["retry-after": "invalid"], .rateLimited(retryAfter: nil)),
        (500, [:], .http(status: 500, message: "Insufficient credit.")),
    ] {
        let reply = try ReplayTransport.Reply(file: "payment.json", status: status, headers: headers)
        let planner = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([reply]))
        await #expect(throws: expected) { try await planner.plan(PlanRequest(instruction: "Edit", image: photo)) }
        let segmenter = MetaSegmenter(configuration: testConfiguration, transport: ReplayTransport([reply]))
        let segmentError = status == 500 ? LumenError.http(status: 500, message: "internal server error") : expected
        await #expect(throws: segmentError) { try await segmenter.segment(SegmentRequest(image: photo, concept: "coat")) }
        let generator = MetaGenerator(configuration: testConfiguration, transport: ReplayTransport([reply]))
        await #expect(throws: expected) {
            try await generator.generate(GenerateRequest(image: photo, mask: MaskData(size: photo.size, filledWith: 255), prompt: "Edit"))
        }
    }
}

@Test func mapsTimeoutsAndCancellationForEveryModel() async throws {
    let photo = try recordedPhoto()
    for (failure, expected) in [(URLError.Code.timedOut, LumenError.timedOut), (.cancelled, .cancelled)] {
        let reply = ReplayTransport.Reply(failure: failure)
        let planner = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([reply]))
        await #expect(throws: expected) { try await planner.plan(PlanRequest(instruction: "Edit", image: photo)) }
        let segmenter = MetaSegmenter(configuration: testConfiguration, transport: ReplayTransport([reply]))
        await #expect(throws: expected) { try await segmenter.segment(SegmentRequest(image: photo, concept: "coat")) }
        let generator = MetaGenerator(configuration: testConfiguration, transport: ReplayTransport([reply]))
        await #expect(throws: expected) {
            try await generator.generate(GenerateRequest(image: photo, mask: MaskData(size: photo.size, filledWith: 255), prompt: "Edit"))
        }
    }
    #expect(MetaHTTP.error(CancellationError()) as? LumenError == .cancelled)
}

@Test func readsRetryAfterDateAndRejectsMissingKeyBeforeTransport() async throws {
    let now = Date(timeIntervalSince1970: 0)
    #expect(MetaHTTP.retryAfter("Thu, 01 Jan 1970 00:00:30 GMT", now: now) == 30)
    #expect(MetaHTTP.retryAfter("-2", now: now) == 0)
    #expect(MetaHTTP.retryAfter("nan", now: now) == nil)
    let transport = ReplayTransport([])
    let planner = MetaPlanner(configuration: MetaConfiguration(apiKey: "  "), transport: transport)
    await #expect(throws: LumenError.missingKey) { try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto)) }
    #expect(await transport.requests.isEmpty)
}

@Test func cancelledTaskDoesNotSendRequest() async throws {
    let transport = ReplayTransport([])
    let planner = MetaPlanner(configuration: testConfiguration, transport: transport)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto))
    }
    await #expect(throws: LumenError.cancelled) { try await task.value }
    #expect(await transport.requests.isEmpty)
}
