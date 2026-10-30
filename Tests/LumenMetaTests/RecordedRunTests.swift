import Foundation
import LumenCore
import Testing
@testable import LumenMeta

/// A judge with no Meta account replays a recorded edit: each endpoint is answered with what it answered then, in
/// order, streams included, and a run that asks for more than was recorded says so.
@Test func aRecordedRunIsAnsweredAgainWithoutTheNetwork() async throws {
    let live = ReplayTransport([try .init(file: "plan.json"), try .init(file: "sam.sse")])
    let recording = RecordingMetaTransport(live)
    let planner = MetaPlanner(configuration: testConfiguration, transport: recording)
    let segmenter = MetaSegmenter(configuration: testConfiguration, transport: recording)
    let plan = try await planner.plan(PlanRequest(instruction: "Make the coat red", image: testPhoto))
    let segments = try await segmenter.segment(SegmentRequest(image: testPhoto, concept: "red coat"))

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-run-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: folder) }
    try RecordedRun(photo: "coat.jpg", instruction: "Make the coat red", answers: await recording.answers).write(to: folder)
    let run = try RecordedRun.read(folder)
    #expect(run.answers.map(\.path) == ["/v1/chat/completions", "/v1/responses"])

    let replay = ReplayingMetaTransport(run)
    var offline = testConfiguration
    offline.apiKey = "replay"
    #expect(try await MetaPlanner(configuration: offline, transport: replay).plan(PlanRequest(instruction: "Make the coat red", image: testPhoto)) == plan)
    #expect(try await MetaSegmenter(configuration: offline, transport: replay).segment(SegmentRequest(image: testPhoto, concept: "red coat")) == segments)
    #expect(await replay.unused == 0)
    await #expect(throws: LumenError.invalidResponse("The recording has no more answers for /v1/chat/completions: this run went differently from the recorded one.")) {
        try await MetaPlanner(configuration: offline, transport: replay).plan(PlanRequest(instruction: "Again", image: testPhoto))
    }
}
