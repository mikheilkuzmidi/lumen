import Foundation
import LumenCore
import Synchronization
import Testing
@testable import LumenMeta

/// Records the waits instead of sleeping.
private final class Waits: Sendable {
    private let waits = Mutex<[TimeInterval]>([])
    var value: [TimeInterval] { waits.withLock { $0 } }

    func transport(_ base: any MetaTransport, retries: Int = 2) -> RetryingMetaTransport {
        RetryingMetaTransport(base, retries: retries) { [self] wait in waits.withLock { $0.append(wait) } }
    }
}

private func notes(_ body: () async throws -> Void) async rethrows -> [String] {
    let notes = Mutex<[String]>([])
    try await ModelCallNotes.$report.withValue({ note in notes.withLock { $0.append(note) } }) { try await body() }
    return notes.withLock { $0 }
}

@Test func triesARateLimitAgainAfterTheWaitItAsksFor() async throws {
    let replay = ReplayTransport([ReplayTransport.Reply(status: 429, headers: ["retry-after": "3"]), try .init(file: "plan.json")])
    let waits = Waits()
    let planner = MetaPlanner(configuration: testConfiguration, transport: waits.transport(replay))
    let said = try await notes { _ = try await planner.plan(PlanRequest(instruction: "Edit", image: try recordedPhoto())) }
    #expect(waits.value == [3])
    #expect(await replay.requests.count == 2)
    #expect(said == ["rate limited; tried again after 3 s"])
}

@Test func anOverloadedServiceIsTriedTwiceMoreWithGrowingWaits() async throws {
    let busy = ReplayTransport.Reply(text: #"{"error":{"message":"overloaded"}}"#, status: 503)
    let replay = ReplayTransport([busy, busy, busy])
    let waits = Waits()
    let planner = MetaPlanner(configuration: testConfiguration, transport: waits.transport(replay))
    await #expect(throws: LumenError.http(status: 503, message: "overloaded")) {
        try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto))
    }
    #expect(await replay.requests.count == 3)
    #expect(waits.value.count == 2)
    #expect((1...1.5).contains(waits.value[0]) && (2...3).contains(waits.value[1]))
}

@Test func neverRetriesWhatAnotherTryCannotFix() async throws {
    for status in [400, 401, 402, 403, 404] {
        let replay = ReplayTransport([ReplayTransport.Reply(status: status)])
        let waits = Waits()
        let planner = MetaPlanner(configuration: testConfiguration, transport: waits.transport(replay))
        await #expect(throws: LumenError.self) { try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto)) }
        #expect(await replay.requests.count == 1, "status \(status)")
        #expect(waits.value.isEmpty)
    }
    // A refusal is a complete answer, not a failure to answer.
    let replay = ReplayTransport([try .init(file: "refusal.json")])
    let planner = MetaPlanner(configuration: testConfiguration, transport: Waits().transport(replay))
    await #expect(throws: LumenError.self) { try await planner.plan(PlanRequest(instruction: "Edit", image: try recordedPhoto())) }
    #expect(await replay.requests.count == 1)
}

@Test func aRateLimitAskingForAMinuteFailsAtOnceWithItsWait() async throws {
    let replay = ReplayTransport([ReplayTransport.Reply(status: 429, headers: ["retry-after": "60"])])
    let waits = Waits()
    let planner = MetaPlanner(configuration: testConfiguration, transport: waits.transport(replay))
    await #expect(throws: LumenError.rateLimited(retryAfter: 60)) {
        try await planner.plan(PlanRequest(instruction: "Edit", image: testPhoto))
    }
    let sent = await replay.requests.count
    #expect(waits.value.isEmpty && sent == 1)
}

@Test func aTimeoutGetsOneMoreTryAndADroppedConnectionTwo() async throws {
    let timeout = ReplayTransport.Reply(failure: .timedOut)
    let timedOut = ReplayTransport([timeout, timeout, try .init(file: "plan.json")])
    let planner = MetaPlanner(configuration: testConfiguration, transport: Waits().transport(timedOut))
    await #expect(throws: LumenError.timedOut) { try await planner.plan(PlanRequest(instruction: "Edit", image: try recordedPhoto())) }
    #expect(await timedOut.requests.count == 2)

    let lost = ReplayTransport.Reply(failure: .networkConnectionLost)
    let dropped = ReplayTransport([lost, lost, try .init(file: "plan.json")])
    let again = MetaPlanner(configuration: testConfiguration, transport: Waits().transport(dropped))
    let said = try await notes { _ = try await again.plan(PlanRequest(instruction: "Edit", image: try recordedPhoto())) }
    #expect(await dropped.requests.count == 3)
    #expect(said.count == 2 && said.allSatisfy { $0.hasPrefix("the connection dropped") })
}

@Test func cancellingDuringTheWaitStops() async throws {
    let replay = ReplayTransport([ReplayTransport.Reply(status: 503), try .init(file: "plan.json")])
    let transport = RetryingMetaTransport(replay) { _ in throw CancellationError() }
    let planner = MetaPlanner(configuration: testConfiguration, transport: transport)
    await #expect(throws: LumenError.cancelled) { try await planner.plan(PlanRequest(instruction: "Edit", image: try recordedPhoto())) }
    #expect(await replay.requests.count == 1)
}

@Test func aStreamedSelectionIsTriedAgainBeforeItsAnswerIsRead() async throws {
    let replay = ReplayTransport([ReplayTransport.Reply(status: 502), try .init(file: "sam.sse")])
    let waits = Waits()
    let segmenter = MetaSegmenter(configuration: testConfiguration, transport: waits.transport(replay))
    let segments = try await segmenter.segment(SegmentRequest(image: testPhoto, concept: "coat"))
    #expect(!segments.isEmpty)
    let sent = await replay.requests.count
    #expect(waits.value.count == 1 && sent == 2)
}
