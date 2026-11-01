import Foundation

/// The few choices Lumen asks the person about, each found the same way in every plan. The planner only says what the
/// instruction's words say (a costume's coverage); these rules decide whether that leaves a choice open, ask the same
/// question every time, and apply the answer to the plan as it stands, with no second plan. Every other instruction
/// is planned with its usual reading and never waits.
public enum QuestionRules {
    /// A costume whose words don't say whether it replaces their clothes or goes over them ("dress him as a knight"):
    /// the redraw covers everything they wear, or only their upper body and head.
    public static let costume = EditQuestion(id: "costume-coverage", question: "Full costume, or over their own clothes?",
                                             options: ["Full costume", "Over their clothes"], recommended: 0)

    /// The question a plan leaves open, if any: at most one per instruction.
    public static func question(for plan: EditPlan) -> EditQuestion? {
        costumes(in: plan).contains { $0.coverage == StyleStep.Coverage.unsaid.rawValue } ? costume : nil
    }

    /// What the plan's own words already decide, as the answer to the question they settle: a costume said to be full
    /// or over the clothes. Kept for the instruction's revisions, so the critic's next plan covers the same.
    public static func stated(in plan: EditPlan) -> [String: String] {
        let said = costumes(in: plan).compactMap { $0.coverage.flatMap(StyleStep.Coverage.init(rawValue:)) }
        if said.contains(.full) { return [costume.id: costume.options[0]] }
        if said.contains(.over) { return [costume.id: costume.options[1]] }
        return [:]
    }

    /// The plan with each decision applied: every costume left open covers what was chosen.
    public static func apply(_ decided: [String: String], to plan: EditPlan) -> EditPlan {
        guard let answer = decided[costume.id] else { return plan }
        let coverage: StyleStep.Coverage = answer == costume.options[0] ? .full : .over
        var plan = plan
        plan.steps = plan.steps.map { step in
            guard case .style(var restyle) = step, restyle.style == "costume",
                  restyle.coverage == StyleStep.Coverage.unsaid.rawValue else { return step }
            restyle.coverage = coverage.rawValue
            return .style(restyle)
        }
        return plan
    }

    private static func costumes(in plan: EditPlan) -> [StyleStep] {
        plan.steps.compactMap { step in
            if case .style(let restyle) = step, restyle.style == "costume" { restyle } else { nil }
        }
    }
}
