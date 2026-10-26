import Foundation
import LumenCore
import Testing
@testable import LumenMeta

private final class RecordedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        if path == "/timeout" || path == "/cancel" {
            client?.urlProtocol(self, didFailWithError: URLError(path == "/timeout" ? .timedOut : .cancelled))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": path == "/stream" ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/stream" {
            for chunk in [Data([239, 187]), Data([191]) + Data("data: first\r".utf8),
                          Data("\n\r\ndata: sec".utf8), Data("ond\r".utf8), Data("\n\r\n".utf8)] {
                client?.urlProtocol(self, didLoad: chunk)
            }
        } else if path == "/responses" {
            let folder = Bundle.module.url(forResource: "Recorded", withExtension: nil)!
            let body = try! Data(contentsOf: folder.appendingPathComponent("sam.sse"))
            for start in stride(from: 0, to: body.count, by: 17) {
                client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + 17, body.count)))
            }
        } else {
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test func urlSessionStreamsACompleteSegmentationResponse() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let segmenter = MetaSegmenter(configuration: MetaConfiguration(apiKey: "recorded-key", baseURL: URL(string: "https://recorded.example")!),
                                  transport: URLSessionMetaTransport(session: session))
    let segments = try await segmenter.segment(SegmentRequest(image: testPhoto, concept: "coat"))
    #expect(segments.count == 1)
    #expect(segments.first?.label == "coat")
    #expect(segments.first?.score == 0.75)
}

@Test func urlSessionTransportReturnsDataAndPreservesSSELines() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = URLSessionMetaTransport(session: session)
    let (data, response) = try await transport.data(for: URLRequest(url: URL(string: "https://recorded.example/json")!))
    #expect(data == Data("{}".utf8))
    #expect(response.statusCode == 200)
    let (stream, streamedResponse) = try await transport.lines(for: URLRequest(url: URL(string: "https://recorded.example/stream")!))
    #expect(streamedResponse.statusCode == 200)
    var lines: [String] = []
    for try await line in stream { lines.append(line) }
    #expect(lines == ["data: first", "", "data: second", ""])
}

@Test func urlSessionTransportMapsConnectionTimeoutAndCancellation() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordedURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let transport = URLSessionMetaTransport(session: session)
    for (path, expected) in [("timeout", LumenError.timedOut), ("cancel", .cancelled)] {
        let call = URLRequest(url: URL(string: "https://recorded.example/\(path)")!)
        await #expect(throws: expected) { try await transport.data(for: call) }
        await #expect(throws: expected) { try await transport.lines(for: call) }
    }
}

private struct InterruptedStream: MetaTransport {
    var cancelled: Bool

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw CancellationError() }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        (AsyncThrowingStream { continuation in
            if cancelled { continuation.finish(throwing: CancellationError()) }
            else { continuation.finish(throwing: URLError(.timedOut)) }
        }, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

@Test func segmenterMapsFailuresDuringStreaming() async throws {
    for (cancelled, expected) in [(true, LumenError.cancelled), (false, .timedOut)] {
        let segmenter = MetaSegmenter(configuration: testConfiguration, transport: InterruptedStream(cancelled: cancelled))
        await #expect(throws: expected) { try await segmenter.segment(SegmentRequest(image: testPhoto, concept: "coat")) }
    }
}
