import Foundation
import LumenMeta

/// Replays recorded bodies and keeps requests for contract assertions.
actor ReplayTransport: MetaTransport {
    struct Reply: Sendable {
        var body: Data
        var status: Int
        var headers: [String: String]
        var failure: URLError.Code?

        init(file: String, status: Int = 200, headers: [String: String] = [:]) throws {
            let folder = Bundle.module.url(forResource: "Recorded", withExtension: nil)!
            body = try Data(contentsOf: folder.appendingPathComponent(file))
            self.status = status
            self.headers = headers
        }

        init(text: String = "", status: Int = 200, headers: [String: String] = [:], failure: URLError.Code? = nil) {
            body = Data(text.utf8)
            self.status = status
            self.headers = headers
            self.failure = failure
        }
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw ReplayError.exhausted }
        let reply = replies.removeFirst()
        if let failure = reply.failure { throw URLError(failure) }
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                          httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        return (AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }, response)
    }

    enum ReplayError: Error { case exhausted }
}
