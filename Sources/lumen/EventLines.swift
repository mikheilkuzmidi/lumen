import Darwin
import Foundation
import LumenCore

struct ConsoleOutput: Sendable {
    private let color = isatty(STDOUT_FILENO) == 1

    func write(_ line: String) {
        let text = color ? "\u{001B}[36m\(line)\u{001B}[0m\n" : line + "\n"
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

/// Pairs model timings with the plan, region or layer they describe.
struct EventLines {
    private var step: EditStep?
    /// The step's model calls by stage; a redraw has its own call and SAM's check of it.
    private var timings: [TraceEvent.Kind: TraceEvent] = [:]

    mutating func accept(_ event: AgentEvent) -> String? {
        switch event {
        case .planned(let plan): return "Plan: \(oneLine(plan.summary))"
        case .stepStarted(_, let next):
            step = next
            timings = [:]
            return nil
        case .selected(let region, let segment):
            return "→ select \(oneLine(region))\(stage(.select)): 1 region, \(Int((segment.mask.area * 100).rounded()))% of the photo"
        case .applied(let layer):
            switch step {
            case .regenerate(let redraw): return "→ redraw \(oneLine(redraw.region))\(stage(.regenerate, checked: true))"
            case .remove(let removal): return "→ remove \(oneLine(removal.region))\(stage(.remove))"
            default: return "→ \(step?.type ?? "apply"): \(oneLine(layer.label))"
            }
        case .reverted:
            if case .revert(let revert) = step { return "→ revert \(oneLine(revert.layer))" }
            return "→ revert"
        case .critiqued(let critique):
            return "Critique: \(critique.satisfied ? "satisfied" : "needs revision"): \(oneLine(critique.notes))"
        case .finished(let reason): return "Finished: \(oneLine(reason))"
        case .trace(let trace):
            if trace.model != nil {
                timings[trace.kind] = trace
                return nil
            }
            switch trace.kind {
            case .failure: return "Failed: \(oneLine(trace.detail))"
            case .plan: return "Plan: \(oneLine(trace.detail))"
            case .select: return "→ select\(stage(.select)): \(oneLine(trace.detail))"
            default: return nil
            }
        }
    }

    /// The model and time of one stage of the step; a checked redraw adds SAM's look at it.
    private func stage(_ kind: TraceEvent.Kind, checked: Bool = false) -> String {
        guard let timing = timings[kind], let model = timing.model else { return "" }
        var text = "\(modelName(model)), \(seconds(timing.duration))"
        if checked, let check = timings[.select], let checker = check.model {
            text += "; checked by \(modelName(checker)), \(seconds(check.duration))"
        }
        return " (\(text))"
    }

    private func modelName(_ id: String) -> String {
        switch id {
        case "sam-3.1": "SAM 3.1"
        case "muse-image-1.0": "Muse Image"
        case "muse-spark-1.3": "Muse Spark"
        case "muse-glimmer": "Muse Glimmer"
        default: id
        }
    }
}

func seconds(_ duration: TimeInterval) -> String {
    String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), duration)
}

func oneLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
}
