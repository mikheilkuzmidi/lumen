import Foundation
import LumenMeta

/// Talks to llama-server for Muse Glimmer's plans, critiques and library reviews: no key, keys in the order Glimmer
/// should write them, and the schema in the nested format llama-server 0.7 constrains to. The direct format it ignores
/// there, so it is sent only to a version that asks for it.
public struct GlimmerChatTransport: MetaTransport {
    let transport: any MetaTransport

    public init(transport: any MetaTransport = RetryingMetaTransport()) {
        self.transport = transport
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) {
            request.httpBody = Data(OrderedJSON.text(json).utf8)
        }
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard needsSchemaKey(response, data: data),
              let body = request.httpBody,
              var json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let format = json["response_format"] as? [String: Any],
              format["type"] as? String == "json_schema",
              let wrapper = format["json_schema"] as? [String: Any], let schema = wrapper["schema"] else {
            return (data, response)
        }
        json["response_format"] = ["type": "json_schema", "schema": schema]
        request.httpBody = Data(OrderedJSON.text(json).utf8)
        try Task.checkCancellation()
        return try await transport.data(for: request)
    }

    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        return try await transport.lines(for: request)
    }

    private func needsSchemaKey(_ response: HTTPURLResponse, data: Data) -> Bool {
        guard [400, 422, 500].contains(response.statusCode),
              let failure = try? JSONDecoder().decode(Failure.self, from: data) else { return false }
        let message = failure.error.message.lowercased()
        return message.contains("key 'schema' not found")
            || (message.contains("response_format.schema") && (message.contains("required") || message.contains("missing")))
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}

/// llama.cpp's grammar writes an object's keys in the order the schema lists them, so a step's type has to come
/// before its other fields, a plan's summary before its steps, and a review's photo number before what it says about
/// the photo: otherwise the model commits to fields before it has said what they are about. JSON text with keys in
/// that order, the rest alphabetical.
enum OrderedJSON {
    private static let leading = ["type", "summary", "notes", "satisfied", "id", "number", "region", "layer", "concept"]

    static func text(_ value: Any) -> String {
        switch value {
        case let object as [String: Any]:
            let keys = object.keys.sorted { first, second in
                let a = leading.firstIndex(of: first) ?? leading.count, b = leading.firstIndex(of: second) ?? leading.count
                return a == b ? first < second : a < b
            }
            return "{" + keys.map { string($0) + ":" + text(object[$0]!) }.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(text).joined(separator: ",") + "]"
        case let string as String:
            return self.string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return String(decoding: (try? JSONSerialization.data(withJSONObject: number, options: .fragmentsAllowed)) ?? Data("0".utf8),
                          as: UTF8.self)
        default:
            return "null"
        }
    }

    private static func string(_ value: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
