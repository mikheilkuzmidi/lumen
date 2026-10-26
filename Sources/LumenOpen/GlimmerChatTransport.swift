import Foundation
import LumenMeta

/// Accommodates llama-server versions that expect the schema directly in the response format.
struct GlimmerChatTransport: MetaTransport {
    let transport: any MetaTransport

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
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
        request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try Task.checkCancellation()
        return try await transport.data(for: request)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
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
