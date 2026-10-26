import ArgumentParser
import Foundation
import LumenCore
import LumenMeta
import LumenRender

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Review and edit a folder of photos.")

    @Argument(help: "The folder of original photos.")
    var folder: String

    @Argument(help: "An optional instruction for the library.")
    var instruction: String?

    @Option(help: "The folder for exported photos, sidecars and the batch report.")
    var out: String

    @Option(help: "How to decide: autonomous, ask or plan.", transform: parseBatchMode)
    var mode: BatchMode = .askWhenUnsure

    @Flag(help: "Skip automatic tone and colour.")
    var noAuto = false

    @Option(help: "Whether to straighten tilted photos: yes, no or ask.")
    var straighten: BatchStraightening = .ask

    @Flag(help: "Keep misfires in the editing pass.")
    var noFlag = false

    @Option(help: "Quality below which a photo gets a closer look, from 0 to 1.")
    var quality = 0.5

    @Option(help: "How many photos to edit at once.")
    var concurrency = 3

    @Option(help: "The maximum number of model calls for the whole batch.")
    var maxCalls: Int?

    @Option(help: "A JSON object mapping question ids to option text.")
    var answers: String?

    @Flag(help: "Approve a plan without prompting.")
    var yes = false

    @Option(help: "The per-photo planner: meta, glimmer or spark-open. Library review always uses Muse Spark.")
    var backend: Backend = .meta

    var batchOptions: BatchOptions {
        BatchOptions(mode: mode, instruction: instruction, auto: !noAuto, straighten: straighten.value,
                     flagMisfires: !noFlag, qualityThreshold: quality, concurrency: concurrency, maxModelCalls: maxCalls)
    }

    mutating func validate() throws {
        guard quality.isFinite, (0...1).contains(quality) else { throw ValidationError("--quality must be from 0 to 1.") }
        guard concurrency > 0 else { throw ValidationError("--concurrency must be greater than zero.") }
        if let maxCalls, maxCalls < 0 { throw ValidationError("--max-calls must be zero or greater.") }
        if let instruction, instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("The instruction must not be empty.")
        }
        guard !folder.isEmpty, !out.isEmpty else { throw ValidationError("The input and output folders must not be empty.") }
        guard URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
                != URL(fileURLWithPath: out).resolvingSymlinksInPath().standardizedFileURL.path.lowercased() else {
            throw ValidationError("The output folder must be separate from the originals.")
        }
    }

    func run() async throws {
        let output = ConsoleOutput()
        let folder = URL(fileURLWithPath: folder)
        let destination = URL(fileURLWithPath: out)
        let supplied = try BatchInput.answers(from: answers.map { URL(fileURLWithPath: $0) })
        let host = try FolderLibrary(folder: folder, output: destination)
        try BatchReport.validate(folder: folder, output: destination, photos: await host.photos(),
                                 answers: answers.map { URL(fileURLWithPath: $0) })
        let models = try backend.models()
        guard let key = ProcessInfo.processInfo.environment["META_API_KEY"] else { throw LumenError.missingKey }
        let reviewer = MetaBatchPlanner(configuration: MetaConfiguration(apiKey: key))
        _ = try await withInterruptCancellation {
            try await backend.withLocalModel(line: output.write) {
                try await BatchRunner.run(host: host, reviewer: reviewer, models: models, options: batchOptions,
                                          output: destination, answers: supplied, approve: yes,
                                          input: .standard, line: output.write)
            }
        }
    }
}

enum BatchStraightening: String, ExpressibleByArgument, Sendable {
    case yes, no, ask
    var value: Bool? {
        switch self {
        case .yes: true
        case .no: false
        case .ask: nil
        }
    }
}

func parseBatchMode(_ text: String) throws -> BatchMode {
    guard let mode = BatchMode(rawValue: text) else { throw ValidationError("--mode must be autonomous, ask or plan.") }
    return mode
}
