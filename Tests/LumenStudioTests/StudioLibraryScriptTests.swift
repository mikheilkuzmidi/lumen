import Foundation
import LumenCore
import Testing
@testable import LumenStudio

@Suite("Library scripts")
struct StudioLibraryScriptTests {
    @Test func parsesDefaultsAndResolvesPaths() throws {
        let script = try StudioLibraryScript.parse(Data(#"{"folder":"photos"}"#.utf8))
        #expect(script.mode == .askWhenUnsure && script.backend == .meta)
        #expect(script.options.auto && script.options.straighten == .ask && script.options.flagMisfires)
        #expect(script.options.qualityThreshold == 0.5 && script.options.concurrency == 3)
        #expect(script.batchOptions.instruction == nil && script.batchOptions.straighten == nil)
        #expect(script.folderURL(relativeTo: URL(fileURLWithPath: "/tmp/run/library.json")).path == "/tmp/run/photos")
    }

    @Test(arguments: BatchMode.allCases)
    func parsesAllModes(mode: BatchMode) throws {
        let data = Data("""
        {"folder":"photos", "instruction":"Make the shirts blue", "mode":"\(mode.rawValue)",
         "backend":"spark-open", "output":"results", "answers":{"style":"Keep each style"}, "approve":false,
         "options":{"auto":false,"straighten":"yes","flagMisfires":false,"qualityThreshold":0.3,"concurrency":2,"maxModelCalls":40}}
        """.utf8)
        let script = try StudioLibraryScript.parse(data)
        #expect(script.mode == mode && script.backend == .sparkOpen)
        #expect(script.batchOptions == BatchOptions(mode: mode, instruction: "Make the shirts blue", auto: false,
            straighten: true, flagMisfires: false, qualityThreshold: 0.3, concurrency: 2, maxModelCalls: 40))
        #expect(script.answers["style"] == "Keep each style" && !script.approve)
        #expect(script.outputURL(relativeTo: URL(fileURLWithPath: "/tmp/run/library.json"))?.path == "/tmp/run/results")
    }

    /// Muse Wonder names its questions, so a script can answer by a word in the question and words in the option; an
    /// answer under the question's own id must still be one of its options; anything else takes the recommendation.
    @Test func answersByIdOrByAWordInTheQuestion() throws {
        let script = try StudioLibraryScript.parse(Data("""
        {"folder":"photos", "answers":{"sweatshirt":"include", "silhouette":"leave", "straighten":"Leave them"}, "visible":true}
        """.utf8))
        #expect(script.visible)
        let sweatshirt = BatchQuestion(id: "include-sweatshirt", question: "Include the woman's red sweatshirt too?",
                                       options: ["Include it", "Leave it out"], recommended: 1)
        let hikers = BatchQuestion(id: "include-hidden", question: "Include the four hikers shown as dark silhouettes?",
                                   options: ["Include them", "Leave them out"], recommended: 0)
        let straighten = BatchQuestion(id: "straighten", question: "Straighten them?", options: ["Straighten them", "Leave them"], recommended: 0)
        let shade = BatchQuestion(id: "shade", question: "Which blue?", options: ["Navy", "Sky"], recommended: 1)
        #expect(try script.answer(to: sweatshirt) == "Include it")
        #expect(try script.answer(to: hikers) == "Leave them out")
        #expect(try script.answer(to: straighten) == "Leave them")
        #expect(try script.answer(to: shade) == "Sky")
        let wrong = try StudioLibraryScript.parse(Data(#"{"folder":"photos", "answers":{"straighten":"Maybe"}}"#.utf8))
        #expect(throws: (any Error).self) { try wrong.answer(to: straighten) }
    }

    @Test(arguments: ["true", "false", "null", "\"ask\"", "\"yes\"", "\"no\""])
    func acceptsStraightenChoices(value: String) throws {
        let script = try StudioLibraryScript.parse(Data("{\"folder\":\"photos\",\"options\":{\"straighten\":\(value)}}".utf8))
        #expect(script.batchOptions.straighten == (["true", "\"yes\""].contains(value) ? true : (["false", "\"no\""].contains(value) ? false : nil)))
    }

    @Test(arguments: ["{}", "{", #"{"folder":" "}"#, #"{"folder":"photos","mode":"maybe"}"#,
        #"{"folder":"photos","backend":"local"}"#, #"{"folder":"photos","options":{"qualityThreshold":1.1}}"#,
        #"{"folder":"photos","options":{"concurrency":0}}"#, #"{"folder":"photos","options":{"maxModelCalls":-1}}"#,
        #"{"folder":"photos","options":{"straighten":"maybe"}}"#, #"{"folder":"photos","window":{"width":100,"height":900}}"#])
    func rejectsInvalidScripts(json: String) {
        #expect(throws: (any Error).self) { try StudioLibraryScript.parse(Data(json.utf8)) }
    }

    @Test func parsesExclusiveLibraryArguments() throws {
        let options = try StudioScriptArguments(["--out", "/tmp/captures", "--library-script", "/tmp/library.json"])
        #expect(options.kind == .library && options.script.path == "/tmp/library.json")
        #expect(throws: (any Error).self) {
            try StudioScriptArguments(["--script", "photo.json", "--library-script", "library.json", "--out", "captures"])
        }
    }

    @MainActor @Test func drivesTheSameFlowWithScriptAnswersAndCapturesEveryMilestone() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let output = fixture.folder.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = try StudioLibraryScript.parse(Data("""
        {"folder":"\(fixture.folder.path)","instruction":"Blue shirts","mode":"plan", "answers":{"style":"Same shirt"}}
        """.utf8))
        let model = fixture.model()
        let photo = StudioModel(makePhoto: { try LibraryTestPhoto(url: $0) })
        let reviewer = LibraryReviewer()
        let runner = StudioLibraryScriptRunner(model: model, photoModel: photo, script: script,
            scriptURL: fixture.folder.appendingPathComponent("library.json"), output: output)
        var snapshots: [LibrarySnapshot] = []
        try await runner.run(using: fixture.models(reviewer: reviewer)) { snapshot in
            snapshots.append(snapshot)
            if snapshot == .question { #expect(model.question != nil) }
            if snapshot == .plan { #expect(model.estimatedModelCalls != nil) }
            if snapshot == .photo { #expect(photo.layers.count == 2 && photo.canUndo) }
        }
        #expect(snapshots == LibrarySnapshot.allCases)
        #expect(model.decisions.first?.answer == "Straighten them")
        #expect(model.decisions.last?.answer == "Same shirt")
        #expect(await reviewer.answers.last?["style"] == "Same shirt")
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("summary.json").path))
        #expect(try String(contentsOf: output.appendingPathComponent("timeline.txt"), encoding: .utf8).contains("Decided: Same shirt"))
    }

    @MainActor @Test func usesRecommendationsWithoutScriptAnswers() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let script = try StudioLibraryScript.parse(Data("""
        {"folder":"\(fixture.folder.path)","instruction":"Blue shirts","options":{"straighten":false}}
        """.utf8))
        let model = fixture.model()
        let runner = StudioLibraryScriptRunner(model: model, photoModel: StudioModel(makePhoto: { try LibraryTestPhoto(url: $0) }), script: script,
            scriptURL: fixture.folder.appendingPathComponent("library.json"), output: fixture.folder)
        try await runner.run(using: fixture.models(reviewer: LibraryReviewer())) { _ in }
        #expect(model.decisions.last?.answer == "Keep each style")
    }
}
