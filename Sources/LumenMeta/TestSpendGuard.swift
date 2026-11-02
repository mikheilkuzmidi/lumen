import Foundation
import LumenCore

/// Opt-in, task-only guard shared with the Python and gateway capture runners.
/// The helper owns an advisory-locked, fsynced ledger. Each URLSession attempt
/// reserves independently, below RetryingMetaTransport. No credentials enter
/// the RPC payload or ledger. Normal application use has no helper dependency.
struct TestSpendGuard: Sendable {
    let helper: String
    let ledger: String
    var denyNetwork = false

    static func configured(_ environment: [String: String]) throws -> Self? {
        let helper = environment["LUMEN_TEST_BUDGET_HELPER"]
        let ledger = environment["LUMEN_TEST_BUDGET_LEDGER"]
        guard helper != nil || ledger != nil || environment["LUMEN_TEST_BUDGET_DENY_NETWORK"] != nil else { return nil }
        guard let helper, let ledger, helper.hasPrefix("/"), ledger.hasPrefix("/"),
              FileManager.default.isReadableFile(atPath: helper) else {
            throw LumenError.invalidResponse("Test budget needs absolute LUMEN_TEST_BUDGET_HELPER and LUMEN_TEST_BUDGET_LEDGER paths. No request sent.")
        }
        return Self(helper: helper, ledger: ledger, denyNetwork: environment["LUMEN_TEST_BUDGET_DENY_NETWORK"] == "1")
    }

    struct Attempt: Sendable {
        var request: URLRequest
        var guardrail: TestSpendGuard?
        var reservation: String?
        var quote: Data?

        func finish(status: Int, data: Data) async throws {
            guard let guardrail, let reservation, let quote else { return }
            let quoteObject = try JSONSerialization.jsonObject(with: quote)
            _ = try await guardrail.call(["operation": "finish", "reservation": reservation,
                                         "quote": quoteObject, "status": status, "bodyBase64": data.base64EncodedString()])
        }

        func uncertain(outcome: String) async {
            guard let guardrail, let reservation else { return }
            // A timeout, cancellation, stream interruption, missing usage, or
            // failed reconciliation never releases its maximum reservation.
            _ = try? await guardrail.call(["operation": "settle", "reservation": reservation, "outcome": outcome])
        }
    }

    static func prepare(_ request: URLRequest, environment: [String: String]) async throws -> Attempt {
        guard let guardrail = try configured(environment) else {
            return Attempt(request: request)
        }
        if Task.isCancelled { throw LumenError.cancelled }
        guard let url = request.url, request.httpBodyStream == nil else {
            throw LumenError.invalidResponse("The test budget cannot classify this request body. No request sent.")
        }
        let answer = try await guardrail.call([
            "operation": "prepare", "url": url.absoluteString, "method": request.httpMethod ?? "GET",
            "contentType": request.value(forHTTPHeaderField: "Content-Type") ?? "",
            "bodyBase64": (request.httpBody ?? Data()).base64EncodedString(),
            "denyNetwork": guardrail.denyNetwork,
        ])
        guard let encoded = answer["bodyBase64"] as? String, let body = Data(base64Encoded: encoded) else {
            throw LumenError.invalidResponse("Invalid test budget helper response. No request sent.")
        }
        var bounded = request
        bounded.httpBody = body.isEmpty && request.httpBody == nil ? nil : body
        bounded.setValue(nil, forHTTPHeaderField: "Content-Length")
        let quote = try answer["quote"].map { try JSONSerialization.data(withJSONObject: $0) }
        let attempt = Attempt(request: bounded, guardrail: guardrail,
                              reservation: answer["reservation"] as? String, quote: quote)
        if Task.isCancelled {
            await attempt.uncertain(outcome: "cancelled")
            throw LumenError.cancelled
        }
        return attempt
    }

    private func call(_ values: [String: Any]) async throws -> [String: Any] {
        var values = values
        values["ledger"] = ledger
        let input = try JSONSerialization.data(withJSONObject: values)
        let helper = helper
        let output: Data = try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", helper]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                try stdin.fileHandleForWriting.write(contentsOf: input)
                try stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return data
            } catch {
                if process.isRunning { process.terminate() }
                throw LumenError.invalidResponse("The test budget helper could not run. Inference refused; reservations are preserved.")
            }
        }.value
        guard let envelope = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              envelope["ok"] as? Bool == true, let result = envelope["result"] as? [String: Any] else {
            let message = (try? JSONSerialization.jsonObject(with: output) as? [String: Any])?["error"] as? String
            throw LumenError.invalidResponse(message ?? "The test budget helper refused inference. Reservations are preserved.")
        }
        return result
    }
}

/// An automatically followed redirect would escape request classification.
final class TestBudgetRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
