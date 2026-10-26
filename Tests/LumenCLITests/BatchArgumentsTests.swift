import ArgumentParser
import Foundation
import LumenCore
import Testing
@testable import lumen

struct BatchArgumentsTests {
    @Test func defaultsAndOptionalInstruction() throws {
        let command = try #require(Lumen.parseAsRoot(["batch", "Fixtures/library", "--out", "results"]) as? Batch)
        #expect(command.folder == "Fixtures/library")
        #expect(command.instruction == nil)
        #expect(command.out == "results")
        #expect(command.batchOptions == BatchOptions())
        #expect(command.backend == .meta)
        #expect(command.answers == nil)
        #expect(!command.yes)
    }

    @Test func allOptions() throws {
        let command = try #require(Lumen.parseAsRoot([
            "batch", "photos", "Make their coats navy", "--out", "results", "--mode", "plan", "--no-auto",
            "--straighten", "no", "--no-flag", "--quality", "0.7", "--concurrency", "8", "--max-calls", "120",
            "--answers", "choices.json", "--yes", "--backend", "spark-open",
        ]) as? Batch)
        #expect(command.batchOptions == BatchOptions(mode: .planFirst, instruction: "Make their coats navy", auto: false,
                                                     straighten: false, flagMisfires: false, qualityThreshold: 0.7,
                                                     concurrency: 8, maxModelCalls: 120))
        #expect(command.answers == "choices.json")
        #expect(command.yes)
        #expect(command.backend == .sparkOpen)
        let autonomous = try Batch.parse(["photos", "--out", "results", "--mode", "autonomous", "--straighten", "yes", "--max-calls", "0"])
        #expect(autonomous.mode == .autonomous)
        #expect(autonomous.batchOptions.straighten == true)
        #expect(autonomous.batchOptions.maxModelCalls == 0)
    }

    @Test(arguments: [
        ["--mode", "manual"], ["--straighten", "maybe"], ["--quality", "nan"], ["--quality", "inf"],
        ["--quality", "1.01"], ["--quality", "-0.1"], ["--concurrency", "0"], ["--concurrency", "-2"],
        ["--max-calls", "-1"], ["--concurrency", "1.5"], ["--backend", "other"], ["--out", "photos"],
    ])
    func rejectsInvalidOptions(_ options: [String]) {
        #expect(throws: (any Error).self) { try Lumen.parseAsRoot(["batch", "photos", "--out", "results"] + options) }
    }

    @Test func requiresOutputAndRejectsEmptyInstructions() {
        #expect(throws: (any Error).self) { try Lumen.parseAsRoot(["batch", "photos"]) }
        #expect(throws: (any Error).self) { try Lumen.parseAsRoot(["batch", "photos", "  ", "--out", "results"]) }
    }

    @Test func invalidAnswersAreRejectedBeforeRunning() throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("answers.json")
        try "{\"style\": 2}".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try BatchInput.answers(from: file) }
    }

    @Test func reportNamesAndSymlinksCannotOverwriteInputs() throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        #expect(throws: (any Error).self) {
            try BatchReport.validate(folder: folder, output: output, photos: [PhotoID("contact-before.jpg")], answers: nil)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("photo.png")
        try PhotoFixtures.image().data.write(to: photo)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("contact-after.jpg"), withDestinationURL: photo)
        #expect(throws: (any Error).self) {
            try BatchReport.validate(folder: folder, output: output, photos: [PhotoID("photo.png")], answers: nil)
        }
        #expect(throws: (any Error).self) {
            try BatchReport.validate(folder: folder, output: output, photos: [], answers: output.appendingPathComponent("batch-trace.json"))
        }
    }
}
