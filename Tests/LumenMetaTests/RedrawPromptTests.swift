import Testing
@testable import LumenMeta

@Test func editingPromptsExplainHowToReplaceABadRedraw() {
    for prompt in [MetaPlanner.planPrompt, MetaPlanner.critiquePrompt] {
        #expect(prompt.contains("regenerate the same region id again"))
        #expect(prompt.contains("Lumen replaces the earlier redraw"))
        #expect(prompt.contains("Do not select the object again"))
    }
}
