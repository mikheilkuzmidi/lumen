import ArgumentParser
import Darwin
import Foundation
import LumenCore

@main
struct Lumen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit a photo by describing the change.",
        subcommands: [Edit.self, Evaluate.self, Batch.self]
    )
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Plan and apply an edit to a photo.")

    @Argument(help: "The photo to edit.")
    var photo: String

    @Argument(help: "What to change, in plain words.")
    var instruction: String

    @OptionGroup var options: EditOptions

    @Option(help: "The result file (.jpg, .jpeg or .png); defaults to <photo name>-lumen.jpg.")
    var out: String?

    @Option(help: "Write the edit trace as JSON.")
    var trace: String?

    var photoURL: URL { URL(fileURLWithPath: photo) }
    var outputURL: URL {
        out.map { URL(fileURLWithPath: $0) }
            ?? photoURL.deletingLastPathComponent()
                .appendingPathComponent(photoURL.deletingPathExtension().lastPathComponent + "-lumen.jpg")
    }
    var traceURL: URL? { trace.map { URL(fileURLWithPath: $0) } }

    mutating func validate() throws {
        try options.validate()
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("The instruction must not be empty.")
        }
        _ = try PhotoOutput.format(for: outputURL)
        try PhotoOutput.validate(photo: photoURL, output: outputURL, trace: traceURL)
    }

    func run() async throws {
        let models = try options.backend.models()
        let output = ConsoleOutput()
        let result = try await withInterruptCancellation {
            try await options.backend.withLocalModel(line: output.write) {
                try await EditRunner.run(photo: photoURL, instruction: instruction, options: options,
                                         models: models, output: outputURL, trace: traceURL, line: output.write)
            }
        }
        if let failure = result.failure { throw CLIError(failure) }
    }
}

struct Evaluate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "eval", abstract: "Run edit cases one at a time.")

    @Argument(help: "A JSON file containing cases with photo and instruction fields.")
    var cases: String

    @Option(help: "The folder for results, traces, comparisons and summary.md.")
    var out: String

    @Option(help: "Run only the case with this name (the photo filename without its extension by default).")
    var only: String?

    @Flag(help: "List the cases and possible model calls without opening photos or calling models.")
    var dryRun = false

    @OptionGroup var options: EditOptions

    mutating func validate() throws { try options.validate() }

    func run() async throws {
        let file = URL(fileURLWithPath: cases)
        let selected = try EvaluationCases.load(file, only: only)
        let output = ConsoleOutput()
        if dryRun {
            for line in EvaluationRunner.dryRun(selected, options: options) { output.write(line) }
            return
        }
        let models = try options.backend.models()
        let failures = try await withInterruptCancellation {
            try await options.backend.withLocalModel(line: output.write) {
                try await EvaluationRunner.run(selected, file: file, folder: URL(fileURLWithPath: out),
                                               options: options, models: models, line: output.write)
            }
        }
        if failures > 0 { throw CLIError("\(failures) evaluation case\(failures == 1 ? "" : "s") failed. See summary.md.") }
    }
}

/// Cancels the active command when the terminal sends an interrupt.
func withInterruptCancellation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let task = Task { try await operation() }
    let previous = signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { task.cancel() }
    source.resume()
    defer {
        source.cancel()
        signal(SIGINT, previous)
    }
    return try await withTaskCancellationHandler {
        do { return try await task.value }
        catch is CancellationError { throw LumenError.cancelled }
    } onCancel: { task.cancel() }
}
