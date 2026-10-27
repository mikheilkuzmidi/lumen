import Foundation
import LumenCore

/// Sends complete responses or streams a response body as lines.
public protocol MetaTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

/// Connects model requests to a URL session.
public struct URLSessionMetaTransport: MetaTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw LumenError.invalidResponse("Expected an HTTP response.")
            }
            return (data, response)
        } catch { throw MetaHTTP.error(error) }
    }

    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw LumenError.invalidResponse("Expected an HTTP response.")
            }
            let lines = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        var line: [UInt8] = []
                        var afterCarriageReturn = false
                        var firstLine = true
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if afterCarriageReturn {
                                afterCarriageReturn = false
                                if byte == 10 { continue }
                            }
                            if byte == 10 || byte == 13 {
                                if firstLine && line.starts(with: [239, 187, 191]) { line.removeFirst(3) }
                                firstLine = false
                                continuation.yield(String(decoding: line, as: UTF8.self))
                                line.removeAll(keepingCapacity: true)
                                afterCarriageReturn = byte == 13
                            } else {
                                line.append(byte)
                            }
                        }
                        if !line.isEmpty {
                            if firstLine && line.starts(with: [239, 187, 191]) { line.removeFirst(3) }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: MetaHTTP.error(error)) }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
            return (lines, response)
        } catch { throw MetaHTTP.error(error) }
    }
}

/// Sends a request again when the service was briefly unable to answer: rate limited, overloaded, or the connection
/// dropped. A wrong key, no credit, a bad request or a refusal is never sent again.
public struct RetryingMetaTransport: MetaTransport {
    public let transport: any MetaTransport
    /// Times a request may be sent again after its first try.
    public var retries: Int
    /// The longest wait before trying again. A rate limit that asks for longer fails at once, with its own wait.
    public var longestWait: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(_ transport: any MetaTransport = URLSessionMetaTransport(), retries: Int = 2, longestWait: TimeInterval = 20) {
        self.init(transport, retries: retries, longestWait: longestWait) { try await Task.sleep(for: .seconds($0)) }
    }

    init(_ transport: any MetaTransport, retries: Int = 2, longestWait: TimeInterval = 20,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.transport = transport
        self.retries = retries
        self.longestWait = longestWait
        self.sleep = sleep
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await retrying({ try await transport.data(for: request) }, response: \.1)
    }

    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        try await retrying({ try await transport.lines(for: request) }, response: \.1)
    }

    private func retrying<Value>(_ send: () async throws -> Value, response: (Value) -> HTTPURLResponse) async throws -> Value {
        var tries = 0
        var timedOut = false
        while true {
            let reason: String
            var asked: TimeInterval?
            do {
                let value = try await send()
                let answer = response(value)
                guard tries < retries, let busy = Self.reason(answer.statusCode) else { return value }
                asked = MetaHTTP.retryAfter(answer.value(forHTTPHeaderField: "retry-after"))
                if let asked, asked > longestWait { return value }
                reason = busy
            } catch {
                let error = MetaHTTP.error(error)
                // A request that timed out already took minutes; it gets one more try, not two.
                let isTimeout = error as? LumenError == .timedOut
                guard tries < retries, !(isTimeout && timedOut), let failure = Self.reason(error) else { throw error }
                timedOut = timedOut || isTimeout
                reason = failure
            }
            tries += 1
            let wait = min(longestWait, asked ?? Double(1 << (tries - 1)) * Double.random(in: 1...1.5))
            ModelCallNotes.report?(String(format: "%@; tried again after %.0f s", locale: Locale(identifier: "en_US_POSIX"),
                                          reason, wait))
            do { try await sleep(wait) } catch { throw LumenError.cancelled }
            if Task.isCancelled { throw LumenError.cancelled }
        }
    }

    static func reason(_ status: Int) -> String? {
        switch status {
        case 429: "rate limited"
        case 500, 502, 503, 504: "the service answered \(status)"
        default: nil
        }
    }

    static func reason(_ error: any Error) -> String? {
        if error as? LumenError == .timedOut { return "timed out" }
        guard let error = error as? URLError else { return nil }
        switch error.code {
        case .networkConnectionLost, .cannotConnectToHost: return "the connection dropped"
        default: return nil
        }
    }
}

enum MetaHTTP {
    static func request(baseURL: URL, path: String, key: String, timeout: TimeInterval,
                        headers: [String: String] = [:], body: [String: Any]) throws -> URLRequest {
        try Task.checkCancellation()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LumenError.missingKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func validate(_ response: HTTPURLResponse, data: Data = Data()) throws {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        switch status {
        case 402: throw LumenError.paymentRequired
        case 429: throw LumenError.rateLimited(retryAfter: retryAfter(response.value(forHTTPHeaderField: "retry-after")))
        case 401, 403: throw LumenError.http(status: status, message: "Check your Meta API key and its model access.")
        default:
            let message = (try? JSONDecoder().decode(Failure.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw LumenError.http(status: status, message: String(message.prefix(240)))
        }
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func error(_ error: any Error) -> any Error {
        if let error = error as? LumenError { return error }
        if error is CancellationError { return LumenError.cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return LumenError.cancelled }
            if error.code == .timedOut { return LumenError.timedOut }
        }
        return error
    }

    static func invalid(_ text: String) -> LumenError {
        .invalidResponse(String(text.prefix(160)))
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}
