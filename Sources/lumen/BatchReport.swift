import Foundation
import LumenCore

enum BatchReport {
    static let filenames = ["batch-summary.md", "batch-trace.json", "contact-before.jpg", "contact-after.jpg"]

    static func write(_ summary: BatchSummary, choices: [String: BatchChoice], to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: folder.appendingPathComponent("batch-trace.json"), options: .atomic)
        try markdown(summary, choices: choices).write(to: folder.appendingPathComponent("batch-summary.md"),
                                                     atomically: true, encoding: .utf8)
    }

    static func markdown(_ summary: BatchSummary, choices: [String: BatchChoice] = [:]) -> String {
        var lines = ["# Batch summary", "",
                     "\(summary.photos.count) \(summary.photos.count == 1 ? "photo" : "photos"); \(summary.modelCalls) model \(summary.modelCalls == 1 ? "call" : "calls"); \(seconds(summary.duration)).", "",
                     "Total cost: \(dollars(summary.totalCost)) USD; \(dollars(summary.costPerPhoto)) per photo (including shared library calls).", "",
                     "| Photo | Flagged | Auto | Tilt measured | Level line | Straightened | Instruction | Outcome |",
                     "| --- | --- | --- | --- | --- | --- | --- | --- |"]
        func degrees(_ value: Double?) -> String {
            value.map { String(format: "%+.1f°", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
        }
        for photo in summary.photos {
            let outcome = (photo.failed ? "Failed: " : "") + (photo.outcome ?? (photo.flagged == nil ? "Kept" : "Flagged"))
            lines.append(row([photo.photo.rawValue, photo.flagged ?? "", photo.auto ?? "", degrees(photo.measuredTilt),
                              photo.levelLine?.rawValue ?? "", degrees(photo.straightened), photo.instruction ?? "", outcome]))
        }
        lines += ["", "## Questions", "", "| ID | Question | Answer | Answered by |", "| --- | --- | --- | --- |"]
        for answer in summary.answers {
            let source = choices[answer.question.id]?.source.rawValue ?? (answer.byPerson ? "person" : "recommendation")
            lines.append(row([answer.question.id, answer.question.question, answer.answer, source]))
        }
        if summary.answers.isEmpty { lines += ["", "No questions were needed."] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Rejects report and export names that overlap inputs or each other.
    static func validate(folder: URL, output: URL, photos: [PhotoID], answers: URL?) throws {
        func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
        var inputs = Set(photos.map { path(folder.appendingPathComponent($0.rawValue)) })
        if let answers { inputs.insert(path(answers)) }
        var destinations = filenames.map { output.appendingPathComponent($0) }
        for photo in photos {
            let name = URL(fileURLWithPath: photo.rawValue)
            let exported = name.pathExtension.lowercased() == "heic"
                ? name.deletingPathExtension().lastPathComponent + ".jpg" : photo.rawValue
            let destination = output.appendingPathComponent(exported)
            destinations += [destination, destination.appendingPathExtension("lumen.json")]
        }
        var seen: Set<String> = []
        for destination in destinations {
            let name = path(destination)
            guard !inputs.contains(name) else { throw CLIError("Batch output would overwrite an input: \(destination.path)") }
            guard seen.insert(name).inserted else { throw CLIError("Batch output filenames overlap: \(destination.path)") }
        }
    }

    private static func row(_ cells: [String]) -> String {
        "| " + cells.map {
            oneLine($0).replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\\", with: "&#92;")
                .replacingOccurrences(of: "|", with: "&#124;")
        }.joined(separator: " | ") + " |"
    }
}
