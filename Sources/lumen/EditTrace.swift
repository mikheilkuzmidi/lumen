import Foundation
import LumenCore

struct ModelIDs: Codable, Equatable, Sendable {
    var planner: String
    var segmenter: String
    var generator: String
}

/// The plans, model calls and layers retained for one instruction.
struct EditTrace: Codable, Sendable {
    var instruction: String
    var backend: Backend
    var modelIDs: ModelIDs
    var events: [TraceEvent] = []
    var plans: [EditPlan] = []
    var critiques: [Critique] = []
    var layerLabels: [String] = []
    var totalTime: TimeInterval = 0
    var stepsApplied = 0
    var revisions = 0
    var exported = false
    var finalReason: String?
    var failure: String?
    /// The person's answers to the planner's question, by question.
    var answers: [String: String]?

    var totalCost: Double { events.reduce(0) { $0 + ($1.cost ?? 0) } }
    var costSummary: String { "Cost: \(dollars(totalCost)) USD · \(modelCalls) model calls" }

    var modelCalls: Int { events.filter { $0.model != nil }.count }
    var verdict: String {
        critiques.last.map { $0.satisfied ? "Satisfied" : "Needs revision" } ?? "Not critiqued"
    }

    func time(for kinds: Set<TraceEvent.Kind>) -> TimeInterval {
        events.filter { $0.model != nil && kinds.contains($0.kind) }.reduce(0) { $0 + $1.duration }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Collects the checked plans while following the agent's revision limits.
struct EditProgress {
    var trace: EditTrace
    var configuration: AgentConfiguration
    private var regions: Set<String> = []
    private var attemptedSteps = 0
    /// Whether a layer was applied or reverted after the recorded failure, so a revision may have made it good.
    private var changedSinceFailure = false

    init(instruction: String, backend: Backend, models: ModelIDs, configuration: AgentConfiguration) {
        trace = EditTrace(instruction: instruction, backend: backend, modelIDs: models)
        self.configuration = configuration
    }

    mutating func accept(_ event: AgentEvent) {
        switch event {
        case .planned(let plan): trace.plans.append(plan)
        case .stepStarted: attemptedSteps += 1
        case .selected(let id, _): regions.insert(id)
        case .applied(let layer):
            trace.layerLabels.append(layer.label)
            trace.stepsApplied += 1
            if trace.failure != nil { changedSinceFailure = true }
        case .reverted:
            trace.stepsApplied += 1
            if trace.failure != nil { changedSinceFailure = true }
        case .critiqued(let critique):
            trace.critiques.append(critique)
            // A failed step that a revision then made good: the critic accepted a result changed after the failure.
            // The failure stays in the events and the printed lines; the run itself succeeded.
            if critique.satisfied, trace.failure != nil, changedSinceFailure {
                trace.failure = nil
                changedSinceFailure = false
            }
            if !critique.satisfied, trace.revisions < configuration.maxRevisions,
               attemptedSteps < configuration.maxSteps {
                trace.revisions += 1
                trace.plans.append(EditPlan(summary: critique.notes, steps: critique.steps).checked(knownRegions: regions).plan)
            }
        case .finished(let reason): trace.finalReason = reason
        case .question: break
        case .answered(let question, let answer): trace.answers = (trace.answers ?? [:]).merging([question.question: answer]) { $1 }
        case .trace(let event):
            trace.events.append(event)
            if event.kind == .failure, trace.failure == nil {
                let prefix = ["select", "adjust", "regenerate", "remove", "crop", "revert"].map { $0 + ": " }
                    .first { event.detail.hasPrefix($0) }
                trace.failure = prefix.map { String(event.detail.dropFirst($0.count)) } ?? event.detail
            }
        }
    }
}
