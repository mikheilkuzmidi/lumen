import Foundation

/// Keeps a plan's values, prompts and region references safe to apply.
struct PlanCheck {
    private var regions: Set<String>
    private var aliases: [String: String] = [:]
    private var notes: [String] = []

    init(knownRegions: Set<String>) {
        regions = knownRegions
    }

    mutating func check(_ plan: EditPlan) -> CheckedPlan {
        var steps: [EditStep] = []
        var finish: Finish?
        var movedFinish = false

        for (index, step) in plan.steps.enumerated() {
            let label = "Step \(index + 1)"
            let checked: EditStep?
            switch step {
            case .select(let selection):
                checked = check(selection, label: label).map(EditStep.select)
            case .adjust(var adjustment):
                if let region = adjustment.region {
                    guard let id = regionID(region, label: label) else { continue }
                    adjustment.region = id
                }
                for key in AdjustmentKey.allCases {
                    guard let value = adjustment.values[key] else { continue }
                    guard value.isFinite else {
                        adjustment.values[key] = nil
                        notes.append("\(label): dropped non-finite \(key.rawValue).")
                        continue
                    }
                    let clamped = min(max(value, key.range.lowerBound), key.range.upperBound)
                    if clamped != value {
                        adjustment.values[key] = clamped
                        notes.append("\(label): clamped \(key.rawValue) to \(clamped).")
                    }
                }
                guard !adjustment.values.isEmpty else {
                    notes.append("\(label): dropped adjustment with no values.")
                    continue
                }
                checked = .adjust(adjustment)
            case .regenerate(var regeneration):
                guard let id = regionID(regeneration.region, label: label) else { continue }
                regeneration.region = id
                guard let prompt = prompt(regeneration.prompt, label: "\(label) prompt") else {
                    notes.append("\(label): dropped regeneration with no prompt.")
                    continue
                }
                regeneration.prompt = prompt
                checked = .regenerate(regeneration)
            case .remove(let removal):
                checked = regionID(removal.region, label: label).map { .remove(Removal(region: $0)) }
            case .crop(let crop):
                checked = rect(crop.rect, label: "\(label) crop").map { .crop(Crop(rect: $0)) }
            case .finish(let proposed):
                if finish == nil {
                    finish = proposed
                } else {
                    notes.append("\(label): dropped extra finish step.")
                }
                continue
            }
            if let checked {
                steps.append(checked)
                if finish != nil { movedFinish = true }
            }
        }
        if let finish {
            steps.append(.finish(finish))
            if movedFinish { notes.append("Moved the finish step to the end.") }
        }
        return CheckedPlan(plan: EditPlan(summary: plan.summary, steps: steps), notes: notes)
    }

    private mutating func check(_ proposed: Selection, label: String) -> Selection? {
        var selection = proposed
        let id = proposed.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            notes.append("\(label): dropped selection with an empty region id.")
            return nil
        }
        if id != proposed.id { notes.append("\(label): trimmed region id to \(id).") }
        if let concept = proposed.concept {
            selection.concept = prompt(concept, label: "\(label) concept")
        }
        if let box = proposed.box { selection.box = rect(box, label: "\(label) selection box") }
        selection.points = proposed.points.enumerated().compactMap { index, point in
            guard point.x.isFinite, point.y.isFinite else {
                notes.append("\(label): dropped non-finite point \(index + 1).")
                return nil
            }
            let clamped = NormalizedPoint(x: unit(point.x), y: unit(point.y))
            if clamped != point { notes.append("\(label): clamped point \(index + 1) to the photo.") }
            return clamped
        }
        guard selection.concept != nil || selection.box != nil || !selection.points.isEmpty else {
            notes.append("\(label): dropped selection with no usable concept, box or points.")
            return nil
        }

        var uniqueID = id
        var suffix = 2
        while regions.contains(uniqueID) {
            uniqueID = "\(id)-\(suffix)"
            suffix += 1
        }
        if uniqueID != id { notes.append("\(label): renamed duplicate region \(id) to \(uniqueID).") }
        selection.id = uniqueID
        regions.insert(uniqueID)
        aliases[id] = uniqueID
        return selection
    }

    private mutating func regionID(_ proposed: String, label: String) -> String? {
        let id = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = aliases[id] ?? id
        guard !id.isEmpty, regions.contains(resolved) else {
            notes.append("\(label): dropped step using unknown region \"\(id)\".")
            return nil
        }
        if id != proposed { notes.append("\(label): trimmed region reference to \(id).") }
        if resolved != id { notes.append("\(label): updated region reference from \(id) to \(resolved).") }
        return resolved
    }

    private mutating func prompt(_ proposed: String, label: String) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notes.append("\(label): dropped empty prompt.")
            return nil
        }
        if trimmed != proposed { notes.append("\(label): trimmed surrounding whitespace.") }
        if trimmed.count > 500 { notes.append("\(label): shortened prompt to 500 characters.") }
        let capped = String(trimmed.prefix(500))
        let prompt = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt != capped { notes.append("\(label): trimmed whitespace after shortening.") }
        return prompt
    }

    private mutating func rect(_ proposed: NormalizedRect, label: String) -> NormalizedRect? {
        guard proposed.x.isFinite, proposed.y.isFinite, proposed.width.isFinite, proposed.height.isFinite else {
            notes.append("\(label): dropped non-finite rectangle.")
            return nil
        }
        let x = unit(proposed.x)
        let y = unit(proposed.y)
        let clamped = NormalizedRect(
            x: x, y: y,
            width: proposed.x >= 0 && proposed.x + proposed.width <= 1 ? proposed.width : unit(proposed.x + proposed.width) - x,
            height: proposed.y >= 0 && proposed.y + proposed.height <= 1 ? proposed.height : unit(proposed.y + proposed.height) - y
        )
        guard clamped.width > 0, clamped.height > 0 else {
            notes.append("\(label): dropped rectangle empty after clamping to the photo.")
            return nil
        }
        if clamped != proposed { notes.append("\(label): clamped rectangle to the photo.") }
        return clamped
    }

    private func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
}
