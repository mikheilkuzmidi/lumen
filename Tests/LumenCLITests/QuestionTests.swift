import Foundation
import LumenCore
import Testing
@testable import lumen

/// `lumen edit` answers the planner's question from --answer, from the terminal, or with the recommendation.
struct QuestionTests {
    let question = EditQuestion(id: "armour", question: "Full suit of armour, or armour over his jacket?",
                                options: ["Full suit of armour", "Armour over his jacket"], recommended: 0)

    @Test func anAnswerGivenNamesAnOptionByItsNumberOrItsWords() async throws {
        let input = BatchScriptedInput([]).input(terminal: true)
        let lines = LineRecorder()
        #expect(try await input.answer(question, supplied: "2", line: lines.append) == "Armour over his jacket")
        #expect(try await input.answer(question, supplied: "full suit", line: lines.append) == "Full suit of armour")
        await #expect(throws: CLIError.self) { try await input.answer(question, supplied: "a cape", line: lines.append) }
        #expect(lines.lines.prefix(3) == ["Question: Full suit of armour, or armour over his jacket?",
                                          "  1. Full suit of armour (recommended)", "  2. Armour over his jacket"])
    }

    @Test func aTerminalIsAskedUntilTheReplyNamesAnOption() async throws {
        let script = BatchScriptedInput(["9", "2"])
        let lines = LineRecorder()
        #expect(try await script.input().answer(question, supplied: nil, line: lines.append) == "Armour over his jacket")
        #expect(lines.lines.contains("Choose a number from 1 to 2, or press Enter for the recommendation."))
        #expect(await script.reads == 2)
        #expect(try await BatchScriptedInput([""]).input().answer(question, supplied: nil, line: { _ in }) == "Full suit of armour")
    }

    @Test func withoutATerminalTheRecommendationIsTakenAndSaid() async throws {
        let script = BatchScriptedInput(["2"])
        let lines = LineRecorder()
        #expect(try await script.input(terminal: false).answer(question, supplied: nil, line: lines.append) == "Full suit of armour")
        #expect(await script.reads == 0)
        #expect(lines.lines.last == "Using the recommendation: Full suit of armour (stdin is not a terminal; answer with --answer).")
    }

    @Test func theAnswerIsAnOptionAndPrintedOnce() throws {
        let command = try #require(Lumen.parseAsRoot(["edit", "/tmp/knight.jpg", "Dress him as a knight", "--answer", "Full suit"]) as? Edit)
        #expect(command.answer == "Full suit")
        var lines = EventLines()
        #expect(lines.accept(.question(question)) == nil, "the question is shown where it's answered")
        #expect(lines.accept(.answered(question: question, answer: "Full suit of armour")) == nil, "the plan's note says it")
    }
}
