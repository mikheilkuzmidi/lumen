import Foundation
import LumenCore

/// Text and photos sent together to a planner.
public enum ChatContentPart: Sendable {
    case text(String)
    case image(EncodedImage)

    var json: [String: Any] {
        switch self {
        case .text(let text): ["type": "text", "text": text]
        case .image(let image): ["type": "image_url", "image_url": ["url": image.dataURL]]
        }
    }
}

/// Builds structured chat requests for Meta or a compatible hosting provider.
public struct ChatCompletionRequestBuilder: Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var extraHeaders: [String: String]
    public var timeout: TimeInterval

    public init(baseURL: URL, apiKey: String, model: String, extraHeaders: [String: String] = [:], timeout: TimeInterval = 180) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.extraHeaders = extraHeaders
        self.timeout = timeout
    }

    public func request(systemPrompt: String, content: [ChatContentPart], schemaName: String, schema: Data) throws -> URLRequest {
        let schema = try JSONSerialization.jsonObject(with: schema)
        return try MetaHTTP.request(baseURL: baseURL, path: "chat/completions", key: apiKey, timeout: timeout,
                                    headers: extraHeaders, body: [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": content.map(\.json)],
            ],
            "response_format": ["type": "json_schema", "json_schema": ["name": schemaName, "schema": schema, "strict": true]],
        ])
    }

    /// Reads the first answer, preserving refusals as a typed failure.
    public static func decode<Answer: Decodable>(_ type: Answer.Type, from data: Data) throws -> Answer {
        let completion: Completion
        do { completion = try JSONDecoder().decode(Completion.self, from: data) }
        catch { throw MetaHTTP.invalid(String(decoding: data, as: UTF8.self)) }
        guard let message = completion.choices.first?.message else { throw MetaHTTP.invalid("No chat completion choice.") }
        if let refusal = message.refusal { throw LumenError.refused(refusal) }
        guard let content = message.content else { throw MetaHTTP.invalid("No chat completion content.") }
        let text: String
        switch content {
        case .text(let value): text = value
        case .parts(let parts):
            if let refusal = parts.first(where: { $0.type == "refusal" }) {
                throw LumenError.refused(refusal.refusal ?? "The model declined the edit.")
            }
            text = parts.compactMap(\.text).joined()
        }
        do { return try JSONDecoder().decode(type, from: Data(text.utf8)) }
        catch { throw MetaHTTP.invalid(text) }
    }

    private struct Completion: Decodable {
        struct Choice: Decodable { var message: Message }
        struct Message: Decodable {
            var refusal: String?
            var content: Content?
        }
        struct Part: Decodable {
            var type: String
            var text: String?
            var refusal: String?
        }
        enum Content: Decodable {
            case text(String)
            case parts([Part])

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { self = .text(text) }
                else { self = .parts(try container.decode([Part].self)) }
            }
        }
        var choices: [Choice]
    }
}
