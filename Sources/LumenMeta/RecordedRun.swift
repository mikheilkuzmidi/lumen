import Foundation
import LumenCore

/// A run's answers from the Meta Model API, kept to answer the same run again with no key and no account: a judge
/// replays a recorded edit exactly as the models answered it, every plan, mask, redraw and check.
public struct RecordedRun: Codable, Equatable, Sendable {
    public struct Answer: Codable, Equatable, Sendable {
        /// The endpoint asked, such as `/v1/chat/completions`.
        public var path: String
        public var status: Int
        public var contentType: String?
        /// The answer as sent: JSON, or a server-sent event stream.
        public var body: String
    }

    /// What was edited, for a replay to say when it is given another photo or instruction.
    public var photo: String
    public var instruction: String
    public var recorded: Date
    public var answers: [Answer]

    public init(photo: String, instruction: String, recorded: Date = Date(), answers: [Answer] = []) {
        self.photo = photo
        self.instruction = instruction
        self.recorded = recorded
        self.answers = answers
    }

    public static func read(_ url: URL) throws -> RecordedRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(RecordedRun.self, from: Data(contentsOf: url)) }
        catch { throw LumenError.invalidResponse("Couldn't read the recorded run: \(error.localizedDescription)") }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Sends requests on and keeps each answer, for `RecordedRun`.
public actor RecordingMetaTransport: MetaTransport {
    private let transport: any MetaTransport
    private(set) public var answers: [RecordedRun.Answer] = []

    public init(_ transport: any MetaTransport = RetryingMetaTransport()) { self.transport = transport }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.data(for: request)
        keep(request, response, String(decoding: data, as: UTF8.self))
        return (data, response)
    }

    /// A stream is read to its end before it is handed on, so what is kept is all of it.
    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (stream, response) = try await transport.lines(for: request)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        keep(request, response, lines.joined(separator: "\n"))
        return (Self.stream(lines), response)
    }

    private func keep(_ request: URLRequest, _ response: HTTPURLResponse, _ body: String) {
        answers.append(RecordedRun.Answer(path: request.url?.path ?? "", status: response.statusCode,
                                          contentType: response.value(forHTTPHeaderField: "Content-Type"), body: body))
    }

    static func stream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

/// Answers each request with the next answer recorded for its endpoint, without the network or a key.
public actor ReplayingMetaTransport: MetaTransport {
    private var queues: [String: [RecordedRun.Answer]] = [:]

    public init(_ run: RecordedRun) {
        for answer in run.answers { queues[answer.path, default: []].append(answer) }
    }

    /// How many recorded answers no request has asked for yet.
    public var unused: Int { queues.values.reduce(0) { $0 + $1.count } }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = try next(request)
        return (Data(answer.body.utf8), Self.response(answer, request))
    }

    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let answer = try next(request)
        let lines = answer.body.components(separatedBy: "\n")
        return (RecordingMetaTransport.stream(lines), Self.response(answer, request))
    }

    private func next(_ request: URLRequest) throws -> RecordedRun.Answer {
        try Task.checkCancellation()
        let path = request.url?.path ?? ""
        guard var queue = queues[path], !queue.isEmpty else {
            throw LumenError.invalidResponse("The recording has no more answers for \(path): this run went differently from the recorded one.")
        }
        let answer = queue.removeFirst()
        queues[path] = queue
        return answer
    }

    private static func response(_ answer: RecordedRun.Answer, _ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url ?? URL(string: "https://api.meta.ai")!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                        headerFields: answer.contentType.map { ["Content-Type": $0] } ?? [:])!
    }
}
