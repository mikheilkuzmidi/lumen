import Foundation
import LumenCore
import Testing
@testable import LumenMeta

@Test func samStreamReadsDeltasOrFinalTextWithoutDuplicatingFinalizers() async throws {
    let line = segmentLine()
    let events = [laneEvent("response.output_text.delta", ["delta": String(line.prefix(30))]),
                  laneEvent("response.output_text.delta", ["delta": String(line.dropFirst(30))]),
                  laneEvent("response.output_text.done", ["text": line]),
                  laneEvent("response.content_part.done", ["part": ["type": "output_text", "text": line]]),
                  ["type": "response.completed"]]
    #expect(try await readEvents(events) == line)
    #expect(try await readEvents([laneEvent("response.output_text.done", ["text": line]), ["type": "response.completed"]]) == line)
    #expect(try await readEvents([laneEvent("response.content_part.done", ["part": ["type": "output_text", "text": ""]]),
                                 ["type": "response.completed"]]) == "")
    #expect(try await readEvents([laneEvent("response.content_part.done", ["part": ["type": "reasoning_text", "text": "ignored"]]),
                                 laneEvent("response.output_text.done", ["text": line])]) == line)
    #expect(try await readEvents([laneEvent("response.output_text.delta", ["delta": line])]) == line)
}

@Test func samStreamRejectsConflictingLanesAndFinalizers() async throws {
    let delta = laneEvent("response.output_text.delta", ["delta": "first"])
    let done = laneEvent("response.output_text.done", ["text": "first"])
    let part = laneEvent("response.content_part.done", ["part": ["type": "output_text", "text": "first"]])
    let cases: [[[String: Any]]] = [
        [delta, laneEvent("response.output_text.delta", ["delta": "second", "item_id": "another"])],
        [delta, laneEvent("response.output_text.done", ["text": "different"])],
        [done, delta], [done, done], [done, part, done], [part, done, part],
        [done, laneEvent("response.content_part.done", ["part": ["type": "output_text", "text": "different"]])],
        [["type": "response.output_text.delta", "delta": "missing lane"]],
        [laneEvent("response.output_text.delta", ["delta": "bad index", "output_index": -1])],
        [delta, ["type": "response.completed"]],
        [["type": "response.completed", "response": ["output": [["content": [["type": "output_text", "text": "aggregate"]]]]]]],
    ]
    for events in cases {
        await #expect(throws: LumenError.self) { try await readEvents(events) }
    }
}

@Test func samStreamPropagatesRefusalsFailuresAndIncompleteResults() async throws {
    let refusals = [laneEvent("response.refusal.delta", ["delta": "Declined"]),
                    laneEvent("response.refusal.done", ["refusal": "Declined"]),
                    laneEvent("response.content_part.done", ["part": ["type": "refusal", "refusal": "Declined"]])]
    for event in refusals {
        await #expect(throws: LumenError.refused("Declined")) { try await readEvents([event]) }
    }
    await #expect(throws: LumenError.invalidResponse("stream failed")) {
        try await readEvents([["type": "error", "message": "stream failed"]])
    }
    await #expect(throws: LumenError.invalidResponse("model failed")) {
        try await readEvents([["type": "response.failed", "response": ["error": ["message": "model failed"]]]])
    }
    await #expect(throws: LumenError.invalidResponse("max_output_tokens")) {
        try await readEvents([laneEvent("response.output_text.done", ["text": ""]),
                              ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]]])
    }
}

@Test func samStreamUnderstandsSSEFraming() async throws {
    let event = String(decoding: try JSONSerialization.data(withJSONObject: laneEvent("response.output_text.done", ["text": "whole"])), as: UTF8.self)
    let stream = AsyncThrowingStream<String, Error> { continuation in
        for line in [": keepalive", "event: response.output_text.done", "data: " + event, "", "data: [DONE]", ""] {
            continuation.yield(line)
        }
        continuation.finish()
    }
    #expect(try await SAMResponseText.read(stream) == "whole")
    let malformed = AsyncThrowingStream<String, Error> { continuation in
        continuation.yield("data: {broken")
        continuation.finish()
    }
    await #expect(throws: LumenError.invalidResponse("{broken")) { try await SAMResponseText.read(malformed) }
}
