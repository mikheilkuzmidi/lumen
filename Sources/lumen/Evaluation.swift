import Foundation
import LumenCore

struct EvaluationCase: Sendable {
    var name: String
    var photo: URL
    var instruction: String
}

enum EvaluationCases {
    private struct File: Decodable {
        struct Entry: Decodable {
            var name: String?
            var photo: String
            var instruction: String
        }
        var cases: [Entry]
    }

    static func load(_ url: URL, only: String? = nil) throws -> [EvaluationCase] {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        var names: Set<String> = []
        let cases = try file.cases.map { entry in
            guard !entry.photo.isEmpty, !entry.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError("Every case needs a photo path and a nonempty instruction.")
            }
            let photo = URL(fileURLWithPath: entry.photo, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
            let stem = entry.name ?? photo.deletingPathExtension().lastPathComponent
            guard !stem.isEmpty, stem != ".", stem != "..",
                  !stem.contains("/"), !stem.contains("\\"),
                  !stem.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CLIError("A case name must be a single, nonempty filename without an extension.")
            }
            var name = stem
            var suffix = 2
            while names.contains(name.lowercased()) && entry.name == nil {
                name = "\(stem)-\(suffix)"
                suffix += 1
            }
            guard names.insert(name.lowercased()).inserted else { throw CLIError("Duplicate case name: \(name).") }
            return EvaluationCase(name: name, photo: photo, instruction: entry.instruction)
        }
        guard let only else { return cases }
        let selected = cases.filter { $0.name == only }
        guard !selected.isEmpty else { throw CLIError("No evaluation case named “\(only)”.") }
        return selected
    }
}

enum EvaluationRunner {
    static func dryRun(_ cases: [EvaluationCase], options: EditOptions) -> [String] {
        cases.flatMap { item in
            let description = "\(item.name): \(oneLine(item.instruction)) [\(item.photo.path)]"
            guard options.maxSteps > 0 else { return [description, "  No model calls (--max-steps 0)."] }
            let planner: String
            switch options.backend {
            case .meta: planner = "muse-spark-1.3"
            case .glimmer: planner = "muse-glimmer on this Mac"
            case .sparkOpen: planner = "Muse Spark Open on its hosting provider"
            }
            return [description,
                    "  Plan: \(planner); select: sam-3.1 when a region is needed; redraw/remove: muse-image-1.0 when requested by the plan; critique: \(planner).",
                    "  At most \(options.maxSteps) steps and \(options.maxRevisions) revisions. Exact calls depend on the plan, selections and verdicts."]
        }
    }

    static func run(_ cases: [EvaluationCase], file: URL, folder: URL, options: EditOptions,
                    models: EditModels, line: @Sendable (String) -> Void) async throws -> Int {
        try validateOutputs(cases, file: file, folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows: [(EvaluationCase, EditTrace)] = []
        let summary = folder.appendingPathComponent("summary.md")
        try markdown(rows).write(to: summary, atomically: true, encoding: .utf8)
        for item in cases {
            try Task.checkCancellation()
            line("Case \(item.name): \(oneLine(item.instruction))")
            let output = folder.appendingPathComponent(item.name + ".jpg")
            let trace = folder.appendingPathComponent(item.name + ".trace.json")
            var result: EditTrace
            do {
                result = try await EditRunner.run(photo: item.photo, instruction: item.instruction,
                                                  options: options, models: models, output: output, trace: trace, line: line)
            } catch {
                result = EditTrace(instruction: item.instruction, backend: options.backend, modelIDs: models.ids)
                result.failure = error.localizedDescription
            }
            if result.exported && !Task.isCancelled {
                do {
                    try await PhotoComparison.write(before: item.photo, after: output,
                                                    to: folder.appendingPathComponent(item.name + ".compare.jpg"))
                } catch { result.failure = error.localizedDescription }
            }
            do { try result.write(to: trace) }
            catch { result.failure = error.localizedDescription }
            rows.append((item, result))
            try markdown(rows).write(to: summary, atomically: true, encoding: .utf8)
            if Task.isCancelled { throw LumenError.cancelled }
        }
        line("Total cost: \(dollars(rows.reduce(0) { $0 + $1.1.totalCost })) USD")
        return rows.filter { $0.1.failure != nil }.count
    }

    static func markdown(_ rows: [(EvaluationCase, EditTrace)]) -> String {
        var lines = [
            "# Evaluation", "",
            "Steps applied counts layers; selection steps do not add a layer. Model calls include failed calls. Times are seconds spent in each model stage.", "",
            "| Case | Instruction | Steps applied | Revisions | Final verdict | Plan | Select | Redraw | Critique | Model calls | Cost | Failure | Judged |",
            "| --- | --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |",
        ]
        for (item, trace) in rows {
            let cells = [item.name, item.instruction, String(trace.stepsApplied), String(trace.revisions), trace.verdict,
                         seconds(trace.time(for: [.plan])), seconds(trace.time(for: [.select])),
                         seconds(trace.time(for: [.regenerate, .remove])), seconds(trace.time(for: [.critique])),
                         String(trace.modelCalls), dollars(trace.totalCost), trace.failure ?? "", ""]
            lines.append("| " + cells.map(markdownCell).joined(separator: " | ") + " |")
        }
        lines += ["", "Total cost: \(dollars(rows.reduce(0) { $0 + $1.1.totalCost })) USD."]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func markdownCell(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\", with: "&#92;")
            .replacingOccurrences(of: "|", with: "&#124;")
    }

    private static func validateOutputs(_ cases: [EvaluationCase], file: URL, folder: URL) throws {
        func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
        let originals = Set(cases.map { path($0.photo) } + [path(file)])
        var outputs = [folder.appendingPathComponent("summary.md")]
        for item in cases {
            outputs += [".jpg", ".trace.json", ".compare.jpg"].map { folder.appendingPathComponent(item.name + $0) }
        }
        var seen: Set<String> = []
        for output in outputs {
            let name = path(output)
            guard !originals.contains(name) else { throw CLIError("Evaluation output would overwrite an input: \(output.path)") }
            guard seen.insert(name).inserted else { throw CLIError("Evaluation output filenames overlap: \(output.path)") }
        }
    }
}
