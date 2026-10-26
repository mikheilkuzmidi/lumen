import Foundation
import LumenCore

/// How to reach the Meta Model API, and which models answer.
public struct MetaConfiguration: Sendable {
    public var apiKey: String
    public var baseURL: URL
    public var planningModel: String
    public var segmentationModel: String
    public var imageModel: String
    public var timeout: TimeInterval

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.meta.ai/v1")!, planningModel: String = "muse-spark-1.3",
                segmentationModel: String = "sam-3.1", imageModel: String = "muse-image-1.0", timeout: TimeInterval = 120) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.planningModel = planningModel
        self.segmentationModel = segmentationModel
        self.imageModel = imageModel
        self.timeout = timeout
    }

    /// The user's own key, from META_API_KEY. Lumen Studio keeps it in the Keychain instead.
    public static func fromEnvironment() throws -> MetaConfiguration {
        guard let key = ProcessInfo.processInfo.environment["META_API_KEY"], !key.isEmpty else { throw LumenError.missingKey }
        return MetaConfiguration(apiKey: key)
    }
}

/// Muse Spark plans an instruction into steps and judges the result.
public struct MetaPlanner: Planner {
    public let configuration: MetaConfiguration
    public var modelID: String { configuration.planningModel }

    public init(configuration: MetaConfiguration) { self.configuration = configuration }

    public func plan(_ request: PlanRequest) async throws -> EditPlan { throw LumenError.notBuilt("Muse Spark planning") }
    public func critique(_ request: CritiqueRequest) async throws -> Critique { throw LumenError.notBuilt("Muse Spark critique") }
}

/// SAM 3.1 finds things by words, a box or points.
public struct MetaSegmenter: Segmenter {
    public let configuration: MetaConfiguration
    public var modelID: String { configuration.segmentationModel }

    public init(configuration: MetaConfiguration) { self.configuration = configuration }

    public func segment(_ request: SegmentRequest) async throws -> [Segment] { throw LumenError.notBuilt("SAM 3.1 selection") }
}

/// Muse Image redraws a region.
public struct MetaGenerator: Generator {
    public let configuration: MetaConfiguration
    public var modelID: String { configuration.imageModel }

    public init(configuration: MetaConfiguration) { self.configuration = configuration }

    public func generate(_ request: GenerateRequest) async throws -> EncodedImage { throw LumenError.notBuilt("Muse Image generation") }
}
