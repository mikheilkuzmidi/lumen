import Foundation
import LumenCore

/// Turns library events into compact console progress.
struct BatchEventLines {
    private var numbers: [PhotoID: Int]
    private var total = 0
    private var measured = 0
    private var measurementsPrinted = false
    private var edits: [PhotoID: EventLines] = [:]

    init(photos: [PhotoID]) {
        numbers = [:]
        for (index, photo) in photos.enumerated() { numbers[photo] = index + 1 }
    }

    mutating func accept(_ event: BatchEvent) -> [String] {
        switch event {
        case .found(let count):
            total = count
            return ["Found \(count) photos."]
        case .measured:
            measured += 1
            return []
        default: break
        }
        var lines: [String] = []
        if !measurementsPrinted {
            measurementsPrinted = true
            lines.append("Measured \(measured) of \(total) photos.")
        }
        switch event {
        case .reviewed(let review):
            let quality = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), review.quality)
            let name = oneLine(review.photo.rawValue)
            let compact = name.count > 42 ? String(name.prefix(41)) + "…" : name
            lines.append("\(numbers[review.photo] ?? 0) \(compact) quality \(quality), group \(oneLine(review.group)), \(review.matchesInstruction ? "matches" : "no match")\(review.tilted == true ? ", tilted" : "")")
        case .flagged(let photo, let reason): lines.append("\(oneLine(photo.rawValue)): Flagged: \(oneLine(reason))")
        case .autoApplied(let photo, let label): lines.append("\(oneLine(photo.rawValue)): \(oneLine(label))")
        case .straightened(let photo, let degrees):
            let angle = String(format: "%+.1f°", locale: Locale(identifier: "en_US_POSIX"), degrees)
            lines.append("\(oneLine(photo.rawValue)): Straightened \(angle)")
        case .planned(let plan):
            lines.append("Plan: \(oneLine(plan.summary))")
            for group in plan.groups {
                lines.append("  \(oneLine(group.title)): \(group.photos.count) photos; \(oneLine(group.instruction ?? "Base pass only"))")
            }
        case .answered(let answer):
            lines.append("Answer [\(oneLine(answer.question.id))]: \(oneLine(answer.answer)) (\(answer.byPerson ? "person" : "recommendation"))")
        case .editStarted(let photo, let instruction):
            edits[photo] = EventLines()
            lines.append("\(oneLine(photo.rawValue)): Edit: \(oneLine(instruction))")
        case .edit(let photo, let event):
            var progress = edits[photo] ?? EventLines()
            if let text = progress.accept(event) { lines.append("\(oneLine(photo.rawValue)): \(text)") }
            edits[photo] = progress
        case .editFinished(let result): edits[result.photo] = nil
        case .progress(let done, let total): lines.append("Progress: \(done)/\(total) photos")
        case .finished(let summary):
            let flagged = summary.photos.filter { $0.flagged != nil }.count
            let failed = summary.photos.filter(\.failed).count
            lines.append("Finished: \(summary.photos.count) photos, \(flagged) flagged, \(failed) failed; \(summary.modelCalls) model calls, \(seconds(summary.duration)); \(dollars(summary.totalCost)) USD.")
        default: break
        }
        return lines
    }
}
