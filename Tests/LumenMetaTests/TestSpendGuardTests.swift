import Foundation
import LumenCore
import Testing
@testable import LumenMeta

private final class BudgetRecordedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.value(forHTTPHeaderField: "X-Recorded-Failure") == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = Int(request.value(forHTTPHeaderField: "X-Recorded-Status") ?? "200")!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = request.url!.path.hasSuffix("/responses") ? "event: response.completed\ndata: {}\n\n"
            : "{\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20},\"choices\":[]}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func budgetFixture() throws -> (URL, [String: String]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-budget-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (root, ["LUMEN_TEST_BUDGET_HELPER": repository.appendingPathComponent("scripts/test_budget.py").path,
                   "LUMEN_TEST_BUDGET_LEDGER": root.appendingPathComponent("ledger.json").path])
}

private func budgetRequest() throws -> URLRequest {
    var request = URLRequest(url: URL(string: "https://api.meta.ai/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer recorded-secret-not-written", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "muse-spark-1.3", "messages": []])
    return request
}

private func budgetEntries(_ root: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: root.appendingPathComponent("ledger.json"))
    return try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["entries"] as? [[String: Any]])
}

private func recordedBudgetSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BudgetRecordedProtocol.self]
    return URLSession(configuration: configuration)
}

@Test func testSpendGuardBoundsBeforeSendingAndKeepsPendingReservation() async throws {
    let (root, environment) = try budgetFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let attempt = try await TestSpendGuard.prepare(budgetRequest(), environment: environment)
    let data = try #require(attempt.request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["max_completion_tokens"] as? Int == 8192)
    #expect(try budgetEntries(root).first?["state"] as? String == "reserved")
    let ledgerText = try String(contentsOf: root.appendingPathComponent("ledger.json"), encoding: .utf8)
    #expect(!ledgerText.contains("recorded-secret"))
    #expect(!ledgerText.contains("messages"))
}

@Test func testSpendGuardSettlesActualUsageThroughURLSession() async throws {
    let (root, environment) = try budgetFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = recordedBudgetSession()
    defer { session.invalidateAndCancel() }
    let transport = URLSessionMetaTransport(session: session, budgetEnvironment: environment)
    _ = try await transport.data(for: budgetRequest())
    let entry = try #require(budgetEntries(root).first)
    #expect(entry["state"] as? String == "settled")
    #expect(entry["actualMicros"] as? Int == 210)
}

@Test func testSpendGuardReservesEveryPhysicalRetry() async throws {
    let (root, environment) = try budgetFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = recordedBudgetSession()
    defer { session.invalidateAndCancel() }
    let transport = RetryingMetaTransport(URLSessionMetaTransport(session: session, budgetEnvironment: environment),
                                          retries: 2, longestWait: 0) { _ in }
    var request = try budgetRequest()
    request.setValue("503", forHTTPHeaderField: "X-Recorded-Status")
    let (_, response) = try await transport.data(for: request)
    #expect(response.statusCode == 503)
    let entries = try budgetEntries(root)
    #expect(entries.count == 3)
    #expect(Set(entries.compactMap { $0["id"] as? String }).count == 3)
    #expect(entries.allSatisfy { $0["state"] as? String == "uncertain" })
}

@Test func testSpendGuardTimeoutRetainsReservation() async throws {
    let (root, environment) = try budgetFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = recordedBudgetSession()
    defer { session.invalidateAndCancel() }
    var request = try budgetRequest()
    request.setValue("timeout", forHTTPHeaderField: "X-Recorded-Failure")
    await #expect(throws: LumenError.timedOut) {
        _ = try await URLSessionMetaTransport(session: session, budgetEnvironment: environment).data(for: request)
    }
    #expect(try budgetEntries(root).first?["state"] as? String == "uncertain")
}

@Test func testSpendGuardSAMStreamSettlesOnlyAfterRead() async throws {
    let (root, environment) = try budgetFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = recordedBudgetSession()
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://api.meta.ai/v1/responses")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("{\"model\":\"sam-3.1\",\"stream\":true,\"input\":[{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,AA==\"}]}".utf8)
    let (lines, _) = try await URLSessionMetaTransport(session: session, budgetEnvironment: environment).lines(for: request)
    for try await _ in lines {}
    let entry = try #require(budgetEntries(root).first)
    #expect(entry["state"] as? String == "settled")
    #expect(entry["actualMicros"] as? Int == 2500)
}

@Test func testSpendGuardRefusesPartialConfigurationAndUnknownProvider() async throws {
    let (root, environment) = try budgetFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try TestSpendGuard.configured(["LUMEN_TEST_BUDGET_LEDGER": "/tmp/unused-budget.json"]) }
    var request = try budgetRequest()
    request.url = URL(string: "https://unknown.invalid/v1/chat/completions")!
    await #expect(throws: (any Error).self) { try await TestSpendGuard.prepare(request, environment: environment) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ledger.json").path))
}
