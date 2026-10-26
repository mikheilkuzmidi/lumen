import Foundation

/// What went wrong, in terms a person can act on.
public enum LumenError: Error, Equatable, Sendable, LocalizedError {
    case missingKey
    case paymentRequired
    case rateLimited(retryAfter: TimeInterval?)
    case refused(String)
    case invalidResponse(String)
    case timedOut
    case cancelled
    case unknownRegion(String)
    case http(status: Int, message: String)
    case notBuilt(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No Meta API key. Set META_API_KEY or add one in Lumen Studio's settings."
        case .paymentRequired: "The Meta account has no credit left for this model."
        case .rateLimited(let after): "Meta is limiting requests" + (after.map { String(format: "; try again in %.0f s.", $0) } ?? ".")
        case .refused(let reason): "The model declined: \(reason)"
        case .invalidResponse(let detail): "The model's answer couldn't be used: \(detail)"
        case .timedOut: "The model took too long to answer."
        case .cancelled: "Stopped."
        case .unknownRegion(let id): "No region called “\(id)” was selected before this step."
        case .http(let status, let message): "The request failed (\(status)): \(message)"
        case .notBuilt(let what): "\(what) isn't built yet."
        }
    }
}

/// One thing that happened during an edit, for the timeline and the trace file.
public struct TraceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case plan, select, adjust, regenerate, remove, crop, critique, finish, failure
    }

    public var kind: Kind
    /// The model that answered, for model calls.
    public var model: String?
    public var detail: String
    public var started: Date
    public var duration: TimeInterval

    public init(kind: Kind, model: String? = nil, detail: String, started: Date, duration: TimeInterval) {
        self.kind = kind
        self.model = model
        self.detail = detail
        self.started = started
        self.duration = duration
    }
}

public struct AgentConfiguration: Sendable {
    /// Steps applied for one instruction, across every revision.
    public var maxSteps = 12
    /// Times the planner may look at its result and revise it.
    public var maxRevisions = 2
    /// The long edge of the photo the planner and critic see.
    public var previewLongEdge = 1536

    public init(maxSteps: Int = 12, maxRevisions: Int = 2, previewLongEdge: Int = 1536) {
        self.maxSteps = maxSteps
        self.maxRevisions = maxRevisions
        self.previewLongEdge = previewLongEdge
    }
}

/// What an edit reports as it goes.
public enum AgentEvent: Sendable {
    case planned(EditPlan)
    case stepStarted(index: Int, step: EditStep)
    case selected(region: String, segment: Segment)
    case applied(Layer)
    case critiqued(Critique)
    case finished(reason: String)
    case trace(TraceEvent)
}

/// Plans an instruction, carries out each step as a layer on the host, looks at the result and revises it.
public actor EditAgent {
    public let planner: any Planner
    public let segmenter: any Segmenter
    public let generator: any Generator
    public let host: any EditHost
    public let configuration: AgentConfiguration

    public init(planner: any Planner, segmenter: any Segmenter, generator: any Generator, host: any EditHost,
                configuration: AgentConfiguration = AgentConfiguration()) {
        self.planner = planner
        self.segmenter = segmenter
        self.generator = generator
        self.host = host
        self.configuration = configuration
    }

    /// Runs the instruction; `area` is where the user asked the agent to look.
    public nonisolated func run(_ instruction: String, area: NormalizedRect? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: LumenError.notBuilt("The agent loop")) }
    }
}
