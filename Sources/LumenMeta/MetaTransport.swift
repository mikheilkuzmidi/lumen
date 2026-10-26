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
