import Foundation
import LumenCore

/// Muse Spark Open on a hosting provider's OpenAI-compatible endpoint (Baseten or Modal).
public struct HostedSparkOpenPlanner: Planner {
    public var endpoint: URL
    public var apiKey: String
    public var modelID: String

    public init(endpoint: URL, apiKey: String, modelID: String = "meta-models/muse-spark-open-1026") {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelID = modelID
    }

    public func plan(_ request: PlanRequest) async throws -> EditPlan { throw LumenError.notBuilt("Muse Spark Open planning") }
    public func critique(_ request: CritiqueRequest) async throws -> Critique { throw LumenError.notBuilt("Muse Spark Open critique") }
}

/// Muse Glimmer running on this Mac.
public struct LocalGlimmerPlanner: Planner {
    public var modelID: String

    public init(modelID: String = "muse-glimmer") { self.modelID = modelID }

    public func plan(_ request: PlanRequest) async throws -> EditPlan { throw LumenError.notBuilt("Local Muse Glimmer planning") }
    public func critique(_ request: CritiqueRequest) async throws -> Critique { throw LumenError.notBuilt("Local Muse Glimmer critique") }
}
