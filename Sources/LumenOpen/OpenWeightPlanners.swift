import Foundation
import LumenCore
import LumenMeta

/// Muse Spark Open on a hosting provider's OpenAI-compatible endpoint (Baseten or Modal).
public struct HostedSparkOpenPlanner: Planner {
    public var endpoint: URL
    public var apiKey: String
    public var modelID: String
    public let transport: any MetaTransport

    public init(endpoint: URL, apiKey: String, modelID: String = "meta-models/muse-spark-open-1026",
                transport: any MetaTransport = URLSessionMetaTransport()) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelID = modelID
        self.transport = transport
    }

    /// Reads the provider's base URL, key and optional model override.
    public static func fromEnvironment() throws -> HostedSparkOpenPlanner {
        try fromEnvironment(ProcessInfo.processInfo.environment)
    }

    static func fromEnvironment(_ environment: [String: String]) throws -> HostedSparkOpenPlanner {
        let baseURL = environment["SPARK_OPEN_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = environment["SPARK_OPEN_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = environment["SPARK_OPEN_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL, !baseURL.isEmpty, let key, !key.isEmpty, model != "" else {
            throw ConfigurationError.missingKey(
                "Set SPARK_OPEN_BASE_URL and SPARK_OPEN_API_KEY. SPARK_OPEN_MODEL defaults to "
                + "meta-models/muse-spark-open-1026 for Baseten; set it to your deployed model ID for Modal."
            )
        }
        guard let endpoint = URL(string: baseURL), ["https", "http"].contains(endpoint.scheme?.lowercased()),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw ConfigurationError.invalidBaseURL("SPARK_OPEN_BASE_URL must be an HTTP or HTTPS base URL, including /v1 when required by the provider.")
        }
        return HostedSparkOpenPlanner(endpoint: endpoint, apiKey: key, modelID: model ?? "meta-models/muse-spark-open-1026")
    }

    /// Missing or unusable hosting-provider settings.
    public enum ConfigurationError: Error, Equatable, Sendable, LocalizedError {
        case missingKey(String)
        case invalidBaseURL(String)

        public var errorDescription: String? {
            switch self {
            case .missingKey(let message), .invalidBaseURL(let message): message
            }
        }
    }

    private var planner: MetaPlanner {
        MetaPlanner(configuration: MetaConfiguration(apiKey: apiKey, baseURL: endpoint, planningModel: modelID), transport: transport)
    }

    public func plan(_ request: PlanRequest) async throws -> EditPlan { try await planner.plan(request) }
    public func critique(_ request: CritiqueRequest) async throws -> Critique { try await planner.critique(request) }
}

/// Muse Glimmer running on this Mac.
public struct LocalGlimmerPlanner: Planner {
    public var modelID: String
    public var baseURL: URL
    public let transport: any MetaTransport

    public init(modelID: String = "muse-glimmer", baseURL: URL = URL(string: "http://127.0.0.1:8786/v1")!,
                transport: any MetaTransport = URLSessionMetaTransport()) {
        self.modelID = modelID
        self.baseURL = baseURL
        self.transport = transport
    }

    private var planner: MetaPlanner {
        MetaPlanner(configuration: MetaConfiguration(apiKey: "local-glimmer", baseURL: baseURL, planningModel: modelID),
                    transport: GlimmerChatTransport(transport: transport))
    }

    public func plan(_ request: PlanRequest) async throws -> EditPlan { try await planner.plan(request) }
    public func critique(_ request: CritiqueRequest) async throws -> Critique { try await planner.critique(request) }
}
