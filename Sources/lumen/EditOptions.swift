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
            // Muse Glimmer plans and checks on this Mac; SAM 3.1 and Muse Image still answer through the Meta API.
            guard let key = environment["META_API_KEY"],
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LumenError.missingKey }
            let configuration = MetaConfiguration(apiKey: key)
            return EditModels(planner: LocalGlimmerPlanner(baseURL: Self.glimmerURL(environment)),
                              segmenter: MetaSegmenter(configuration: configuration),
                              generator: MetaGenerator(configuration: configuration))
        case .sparkOpen:
            // Muse Spark Open plans and checks on a hosting provider; SAM 3.1 and Muse Image answer through the Meta API.
            guard let key = environment["META_API_KEY"],
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LumenError.missingKey }
            let configuration = MetaConfiguration(apiKey: key)
            return EditModels(planner: try HostedSparkOpenPlanner.fromEnvironment(environment),
                              segmenter: MetaSegmenter(configuration: configuration),
                              generator: MetaGenerator(configuration: configuration))
        }
    }
}

extension Backend {
    /// Where a running llama-server answers for Muse Glimmer: LUMEN_GLIMMER_URL, or Lumen's own port.
    static func glimmerURL(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["LUMEN_GLIMMER_URL"].flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? URL(string: "http://127.0.0.1:8786/v1")!
    }

    /// Runs `body` with Muse Glimmer serving when this backend needs it. A server that is already answering is
    /// used as it is; one Lumen starts is stopped afterwards.
    func withLocalModel<Value: Sendable>(line: @escaping @Sendable (String) -> Void,
                                         _ body: () async throws -> Value) async throws -> Value {
        guard self == .glimmer else { return try await body() }
        let base = Self.glimmerURL()
        if await Self.answers(base) { return try await body() }
        let server = GlimmerServer(port: base.port ?? 8786)
        line("Loading Muse Glimmer on this Mac…")
        let started = Date()
        do {
            _ = try await server.start()
            line(String(format: "Muse Glimmer is ready (%.0f s).", Date().timeIntervalSince(started)))
            let value = try await body()
            await server.stop()
            return value
        } catch {
            await server.stop()
            throw error
        }
    }

    private static func answers(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent("health"), timeoutInterval: 2)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("ok")
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

    @Option(help: "The long edge in pixels of the photo the planner and critic see; SAM selects at 1536 and exports stay full size.")
    var preview = 1024

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
