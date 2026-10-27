import Foundation
import Synchronization

/// The usage and charge reported by one model call.
public struct ModelUsage: Equatable, Sendable {
    public var cost: Double?
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?

    public init(cost: Double? = nil, inputTokens: Int? = nil, cachedInputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.cost = cost
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

/// Carries usage from a model implementation to the agent tracing the current call.
public enum ModelUsageReporting {
    @TaskLocal public static var report: (@Sendable (ModelUsage) -> Void)?
}

/// Carries what happened inside a model call, such as a retry, to the agent tracing it.
public enum ModelCallNotes {
    @TaskLocal public static var report: (@Sendable (String) -> Void)?
}

/// Supplies a default photo estimate without putting model prices in the core.
public protocol PhotoCostEstimating: Sendable {
    var estimatedCostPerPhoto: Double { get }
}

final class ModelUsageRecorder: Sendable {
    private let usage = Mutex<ModelUsage?>(nil)

    func record(_ value: ModelUsage) { usage.withLock { $0 = value } }
    var value: ModelUsage? { usage.withLock { $0 } }
}

final class ModelCallNoteRecorder: Sendable {
    private let notes = Mutex<[String]>([])

    func record(_ note: String) { notes.withLock { $0.append(note) } }
    var value: [String] { notes.withLock { $0 } }

    /// `detail`, followed by what happened inside the call.
    func detail(_ detail: String) -> String {
        let notes = value
        return notes.isEmpty ? detail : detail + " (" + notes.joined(separator: "; ") + ")"
    }
}

extension TraceEvent {
    func recording(_ usage: ModelUsage?) -> TraceEvent {
        var trace = self
        trace.cost = usage?.cost
        trace.inputTokens = usage?.inputTokens
        trace.cachedInputTokens = usage?.cachedInputTokens
        trace.outputTokens = usage?.outputTokens
        return trace
    }
}
