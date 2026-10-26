import ArgumentParser
import Foundation
import LumenCore
import LumenMeta
import LumenOpen

enum Backend: String, ExpressibleByArgument, Codable, Sendable {
    case meta, glimmer
    case sparkOpen = "spark-open"

    func models(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> EditModels {
        switch self {
        case .meta:
            guard let key = environment["META_API_KEY"],
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LumenError.missingKey }
            let configuration = MetaConfiguration(apiKey: key)
            return EditModels(planner: MetaPlanner(configuration: configuration),
                              segmenter: MetaSegmenter(configuration: configuration),
                              generator: MetaGenerator(configuration: configuration))
        case .glimmer:
            throw LumenError.notBuilt("Local Muse Glimmer planning")
        case .sparkOpen:
            throw LumenError.notBuilt("Muse Spark Open planning")
        }
    }
}

struct EditOptions: ParsableArguments, Sendable {
    @Option(help: "An area x,y,w,h in 0...1 coordinates, measured from the top-left.", transform: parseArea)
    var area: NormalizedRect?

    @Option(help: "The planner backend: meta, glimmer or spark-open.")
    var backend: Backend = .meta

    @Option(help: "Maximum steps across all revisions, including selections (zero skips models).")
    var maxSteps = 12

    @Option(help: "Maximum revisions after the first plan.")
    var maxRevisions = 2

    @Option(help: "The preview long edge in pixels; exports remain full size.")
    var preview = 1536

    var agentConfiguration: AgentConfiguration {
        AgentConfiguration(maxSteps: maxSteps, maxRevisions: maxRevisions, previewLongEdge: preview)
    }

    mutating func validate() throws {
        guard maxSteps >= 0 else { throw ValidationError("--max-steps must be zero or greater.") }
        guard maxRevisions >= 0 else { throw ValidationError("--max-revisions must be zero or greater.") }
        guard preview > 0 else { throw ValidationError("--preview must be greater than zero.") }
    }
}

func parseArea(_ text: String) throws -> NormalizedRect {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite),
          values[0] >= 0, values[1] >= 0, values[2] > 0, values[3] > 0,
          values[0] + values[2] <= 1, values[1] + values[3] <= 1 else {
        throw ValidationError("--area must be x,y,w,h with finite values inside 0...1, positive width and height, and x+w and y+h at most 1.")
    }
    return NormalizedRect(x: values[0], y: values[1], width: values[2], height: values[3])
}

struct EditModels: Sendable {
    var planner: any Planner
    var segmenter: any Segmenter
    var generator: any Generator

    var ids: ModelIDs {
        ModelIDs(planner: planner.modelID, segmenter: segmenter.modelID, generator: generator.modelID)
    }
}

struct CLIError: LocalizedError, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
