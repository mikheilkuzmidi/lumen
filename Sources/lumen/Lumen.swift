import ArgumentParser
import Darwin
import Foundation
import LumenCore
import LumenMeta
import LumenVoice

@main
struct Lumen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit a photo by describing the change.",
        subcommands: [Edit.self, Evaluate.self, Batch.self, Styles.self, Transcribe.self]
    )
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Plan and apply an edit to a photo.")

    @Argument(help: "The photo to edit.")
    var photo: String

    @Argument(help: "What to change, in plain words. Leave it out with --voice.")
    var instruction: String?

    @Option(help: "A recording of the instruction, spoken in any language; Muse Voice Transcribe writes it down.")
    var voice: String?

    @OptionGroup var options: EditOptions

    @Option(help: "The result file (.jpg, .jpeg or .png); defaults to <photo name>-lumen.jpg.")
    var out: String?

    @Option(help: "Write the edit trace as JSON.")
    var trace: String?

    @Option(help: "Restyle the person the instruction names in this style (see lumen styles).")
    var style: String?

    @Option(help: "Grade the photo with this effect (see lumen styles).")
    var effect: String?

    var photoURL: URL { URL(fileURLWithPath: photo) }

    /// The instruction, with the style and effect asked for by name, which the planner takes as its style step.
    var styledInstruction: String { styled(instruction ?? "") }

    func styled(_ instruction: String) -> String {
        let named = [style.map { "style \($0)" }, effect.map { "effect \($0)" }].compactMap { $0 }
        guard !named.isEmpty else { return instruction }
        return instruction + " Use a style step with " + named.joined(separator: " and ") + "."
    }
    var outputURL: URL {
        out.map { URL(fileURLWithPath: $0) }
            ?? photoURL.deletingLastPathComponent()
                .appendingPathComponent(photoURL.deletingPathExtension().lastPathComponent + "-lumen.jpg")
    }
    var traceURL: URL? { trace.map { URL(fileURLWithPath: $0) } }

    mutating func validate() throws {
        try options.validate()
        switch (instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, voice) {
        case (true, nil): break
        case (false, let voice?): try Transcribe.check(voice)
        case (true, _?): throw ValidationError("Give the instruction in words or as --voice, not both.")
        case (false, nil): throw ValidationError("The instruction must not be empty.")
        }
        _ = try PhotoOutput.format(for: outputURL)
        try PhotoOutput.validate(photo: photoURL, output: outputURL, trace: traceURL)
        if let style, PersonStyle.named(style) == nil {
            throw ValidationError("No style called “\(style)”. See lumen styles.")
        }
        if let effect, StyleEffect.named(effect) == nil {
            throw ValidationError("No effect called “\(effect)”. See lumen styles.")
        }
    }

    func run() async throws {
        let models = try options.backend.models()
        let output = ConsoleOutput()
        var said = styledInstruction
        if let voice {
            let transcript = try await Transcribe.transcribe(voice)
            output.write("Heard (Muse Voice Transcribe, \(transcript.seconds) s): \(transcript.text)")
            said = styled(transcript.text)
        }
        let instruction = said
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

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write down a spoken instruction with Muse Voice Transcribe, in the language it was said.")

    @Argument(help: "A recording: any audio file macOS reads (WAV, AIFF, M4A, a voice memo).")
    var audio: String

    mutating func validate() throws { try Self.check(audio) }

    func run() async throws {
        let transcript = try await Self.transcribe(audio)
        print(transcript.text)
        let cost = MetaPricing.cost(model: "muse-voice-transcribe-1.0", audioSeconds: transcript.seconds) ?? 0
        FileHandle.standardError.write(Data("\(transcript.seconds) s of audio, \(String(format: "$%.5f", locale: Locale(identifier: "en_US_POSIX"), cost))\n".utf8))
    }

    static func check(_ path: String) throws {
        guard FileManager.default.isReadableFile(atPath: path) else { throw ValidationError("Can't read the recording at \(path).") }
    }

    static func transcribe(_ path: String) async throws -> Transcript {
        let wav = try SpokenAudio.wav(contentsOf: URL(fileURLWithPath: path))
        return try await MetaTranscriber(configuration: MetaConfiguration.fromEnvironment()).transcribe(wav: wav)
    }
}

struct Styles: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the person styles and effects an edit can use.")

    func run() {
        print("Styles (redraw only the person: their face, head or body, and what goes with it):")
        for style in PersonStyle.all {
            let with = PersonStyle.Piece.allCases.filter { style.pieces.contains($0) }.map(\.rawValue)
            let part = style.part.rawValue + (with.isEmpty ? "" : " with " + with.joined(separator: ", "))
                + (style.adultsOnly ? ", adults only" : "")
            print("  \(style.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(style.title) (\(part))")
        }
        print("Effects:")
        for effect in StyleEffect.all {
            let targets = effect.parts.map(\.target.rawValue).joined(separator: ", ")
            print("  \(effect.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(effect.title) (\(targets))")
        }
    }
}
