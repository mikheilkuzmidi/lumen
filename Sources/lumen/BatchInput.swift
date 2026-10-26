import Darwin
import Foundation
import LumenCore

/// Reads choices without keeping a cancelled command blocked on stdin.
struct BatchInput: Sendable {
    var isTerminal: Bool
    var read: @Sendable () async throws -> String?

    static var standard: BatchInput {
        BatchInput(isTerminal: isatty(STDIN_FILENO) == 1, read: readStandardLine)
    }

    static func answers(from file: URL?) throws -> [String: String] {
        guard let file else { return [:] }
        do { return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)) }
        catch { throw CLIError("Could not read --answers as a JSON object of question ids and option text: \(error.localizedDescription)") }
    }

    func choose(_ question: BatchQuestion, supplied: [String: String], autonomous: Bool,
                line: @Sendable (String) -> Void) async throws -> BatchChoice {
        guard question.options.indices.contains(question.recommended) else { throw CLIError("The question has no valid recommendation.") }
        if !autonomous {
            line("Question [\(oneLine(question.id))]: \(oneLine(question.question))")
            for (index, option) in question.options.enumerated() {
                line("  \(index + 1). \(oneLine(option))\(index == question.recommended ? " (recommended)" : "")")
            }
        }
        if let answer = supplied[question.id] {
            guard question.options.contains(answer) else {
                throw CLIError("Answer for \(question.id) must match one of its option texts.")
            }
            return BatchChoice(text: answer, source: .file)
        }
        let recommended = question.options[question.recommended]
        if autonomous { return BatchChoice(text: recommended, source: .recommendation) }
        if !isTerminal {
            line("Using recommendation for \(oneLine(question.id)): \(oneLine(recommended)) (stdin is not a terminal).")
            return BatchChoice(text: recommended, source: .recommendation)
        }
        while true {
            try Task.checkCancellation()
            line("Choice [\(question.recommended + 1)]:")
            guard let text = try await read() else {
                line("Using recommendation for \(oneLine(question.id)): \(oneLine(recommended)) (end of stdin).")
                return BatchChoice(text: recommended, source: .recommendation)
            }
            let choice = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if choice.isEmpty { return BatchChoice(text: recommended, source: .stdin) }
            if let number = Int(choice), (1...question.options.count).contains(number) {
                return BatchChoice(text: question.options[number - 1], source: .stdin)
            }
            if question.options.contains(choice) { return BatchChoice(text: choice, source: .stdin) }
            line("Choose a number from 1 to \(question.options.count), or press Enter for the recommendation.")
        }
    }

    func approve(line: @Sendable (String) -> Void) async throws -> Bool {
        line("Go ahead? [y/N]")
        let answer = try await read()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    private static func readStandardLine() async throws -> String? {
        var bytes: [UInt8] = []
        while true {
            try Task.checkCancellation()
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                throw CLIError("Could not read stdin.")
            }
            if ready == 0 {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            var byte: UInt8 = 0
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CLIError("Could not read stdin.")
            }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }
}

struct BatchChoice: Sendable {
    enum Source: String, Sendable {
        case stdin, file = "answers file", recommendation
    }
    var text: String
    var source: Source
    var byPerson: Bool { source != .recommendation }
}
