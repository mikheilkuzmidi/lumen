import Foundation
import LumenCore

/// Reads the single output-text lane of a segmentation response.
enum SAMResponseText {
    static func read(_ lines: AsyncThrowingStream<String, Error>) async throws -> String {
        var reader = Reader()
        var data: [String] = []
        var eventName: String?
        for try await line in lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if !data.isEmpty { try reader.accept(data.joined(separator: "\n"), eventName: eventName) }
                data = []
                eventName = nil
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst(5)
                data.append(String(value.first == " " ? value.dropFirst() : value))
            } else if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            }
        }
        if !data.isEmpty { try reader.accept(data.joined(separator: "\n"), eventName: eventName) }
        return reader.text
    }

    private struct Event: Decodable {
        struct Part: Decodable {
            var type: String
            var text: String?
            var refusal: String?
        }
        struct Response: Decodable {
            struct Detail: Decodable { var message: String?; var reason: String? }
            var error: Detail?
            var incomplete_details: Detail?
        }
        var type: String?
        var item_id: String?
        var output_index: Int?
        var content_index: Int?
        var delta: String?
        var text: String?
        var refusal: String?
        var part: Part?
        var message: String?
        var response: Response?
    }

    private struct Lane: Equatable {
        var item: String
        var output: Int
        var content: Int

        init(_ event: Event) throws {
            guard let item = event.item_id, !item.isEmpty,
                  let output = event.output_index, (0...9_007_199_254_740_991).contains(output),
                  let content = event.content_index, (0...9_007_199_254_740_991).contains(content) else {
                throw MetaHTTP.invalid("Invalid SAM output-text lane.")
            }
            self.item = item
            self.output = output
            self.content = content
        }
    }

    private struct Reader {
        var lane: Lane?
        var text = ""
        var sawDelta = false
        var finalizers: Set<String> = []
        var terminal = false

        mutating func accept(_ data: String, eventName: String?) throws {
            if data == "[DONE]" { return }
            let event: Event
            do { event = try JSONDecoder().decode(Event.self, from: Data(data.utf8)) }
            catch { throw MetaHTTP.invalid(data) }
            let type = event.type ?? eventName ?? ""
            switch type {
            case "response.refusal.delta", "response.refusal.done":
                throw LumenError.refused(event.refusal ?? event.delta ?? "The model declined the selection.")
            case "response.content_part.done" where event.part?.type == "refusal":
                throw LumenError.refused(event.part?.refusal ?? "The model declined the selection.")
            case "response.output_text.delta":
                try identify(event)
                guard !terminal, finalizers.isEmpty, let delta = event.delta else {
                    throw MetaHTTP.invalid("SAM text arrived after finalization or without a delta.")
                }
                sawDelta = true
                text += delta
            case "response.output_text.done":
                try finalize(event, type: type, text: event.text)
            case "response.content_part.done" where event.part?.type == "output_text":
                try finalize(event, type: type, text: event.part?.text)
            case "response.completed", "response.incomplete":
                guard !finalizers.isEmpty else { throw MetaHTTP.invalid("SAM ended without finalized output text.") }
                if type == "response.incomplete" {
                    throw MetaHTTP.invalid(event.response?.incomplete_details?.reason ?? "Incomplete SAM response.")
                }
                terminal = true
            case "response.failed", "error":
                throw MetaHTTP.invalid(event.response?.error?.message ?? event.message ?? "SAM response failed.")
            default: break
            }
        }

        mutating func identify(_ event: Event) throws {
            let next = try Lane(event)
            guard lane == nil || lane == next else { throw MetaHTTP.invalid("Interleaved SAM output-text lanes.") }
            lane = next
        }

        mutating func finalize(_ event: Event, type: String, text final: String?) throws {
            try identify(event)
            guard !terminal, !finalizers.contains(type), let final else {
                throw MetaHTTP.invalid("Repeated or missing SAM final text.")
            }
            if sawDelta || !finalizers.isEmpty {
                guard text == final else { throw MetaHTTP.invalid("Conflicting SAM final text.") }
            } else {
                text = final
            }
            finalizers.insert(type)
        }
    }
}
