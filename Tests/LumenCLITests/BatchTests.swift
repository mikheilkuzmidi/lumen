import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import LumenRender
import Testing
@testable import lumen

struct BatchTests {
    @Test func autonomousRunPrintsProgressAndWritesPhotosAndReports() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        let host = try BatchScriptedLibrary(output: output)
        let input = BatchScriptedInput([])
        let lines = LineRecorder()
        let result = try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(question: BatchScriptedReviewer.style),
                                               models: PhotoFixtures.models(), options: BatchOptions(mode: .autonomous, instruction: "Change coats"),
                                               output: output, input: input.input(), line: lines.append)
        #expect(result.photos.count == 4)
        #expect(result.photos.allSatisfy { !$0.failed })
        #expect(result.photos.first { $0.photo == PhotoID("misfire.png") }?.flagged == "Pocket shot")
        #expect(result.photos.first { $0.photo == PhotoID("tilted.png") }?.straightened == -2)
        #expect(result.answers.map(\.byPerson) == [false, false])
        #expect(await input.reads == 0)
        #expect(await host.saved.count == 4)
        #expect(lines.lines.first == "Found 4 photos.")
        #expect(lines.lines.filter { $0.hasPrefix("Measured") } == ["Measured 4 of 4 photos."])
        #expect(lines.lines.contains("1 good.png quality 0.8, group hikers, matches"))
        #expect(lines.lines.contains("misfire.png: Flagged: Pocket shot"))
        #expect(lines.lines.contains("good.png: Auto: exposure +0.3"))
        #expect(lines.lines.contains("tilted.png: Straightened -2.0°"))
        #expect(lines.lines.contains("  Hikers: 3 photos; Make the coat navy"))
        #expect(lines.lines.contains { $0.hasPrefix("low.png: Edit: Improve this photo naturally") })
        #expect(lines.lines.contains { $0.hasPrefix("good.png: → redraw coat (Muse Image,") })
        #expect(lines.lines.contains("Progress: 4/4 photos"))
        #expect(lines.lines.last?.hasPrefix("Finished: 4 photos, 1 flagged, 0 failed;") == true)
        #expect(!lines.lines.contains { $0.hasPrefix("Question") || $0.hasPrefix("Choice") })
        #expect(lines.lines.allSatisfy { !$0.contains("\n") })
        for name in ["good.png", "tilted.png", "misfire.png", "low.png"] {
            #expect(PhotoFixtures.size(of: output.appendingPathComponent(name)) == PixelSize(width: 20, height: 10))
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(name + ".lumen.json").path))
        }
        let trace = try JSONDecoder().decode(BatchSummary.self, from: Data(contentsOf: output.appendingPathComponent("batch-trace.json")))
        #expect(trace == result)
        let markdown = try String(contentsOf: output.appendingPathComponent("batch-summary.md"), encoding: .utf8)
        #expect(markdown.contains("| Photo | Flagged | Auto | Tilt measured | Level line | Straightened | Instruction | Outcome |"))
        #expect(markdown.contains("| misfire.png | Pocket shot |  |  |  |  |  | Flagged |"))
        #expect(markdown.contains("| tilted.png |  | Auto: exposure +0.3 | +2.0° |  | -2.0° | Make the coat navy |"))
        #expect(markdown.contains("| style | Which coat colour? | Navy coats | recommendation |"))
        let size = PixelSize(width: 3 * BatchContactSheet.cellWidth, height: BatchContactSheet.cellHeight)
        #expect(PhotoFixtures.size(of: output.appendingPathComponent("contact-before.jpg")) == size)
        #expect(PhotoFixtures.size(of: output.appendingPathComponent("contact-after.jpg")) == size)
        #expect(try centerGray(output.appendingPathComponent("contact-before.jpg")) < 80)
        #expect(try centerGray(output.appendingPathComponent("contact-after.jpg")) > 160)
    }

    @Test func askModeReadsNumberAndEnterFromScriptedStdin() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try BatchScriptedLibrary(output: folder, names: ["tilted.png"])
        let reviewer = BatchScriptedReviewer(question: BatchScriptedReviewer.style)
        let input = BatchScriptedInput(["-9223372036854775808", "", "2"])
        let lines = LineRecorder()
        let result = try await BatchRunner.run(host: host, reviewer: reviewer, models: PhotoFixtures.models(),
                                               options: BatchOptions(instruction: "Change coats"), output: folder,
                                               input: input.input(), line: lines.append)
        #expect(result.answers.map(\.answer) == ["Straighten them", "Green coats"])
        #expect(result.answers.allSatisfy { $0.byPerson })
        #expect(result.photos.first?.instruction == "Make the coat green")
        #expect(await input.reads == 3)
        #expect(lines.lines.contains("  1. Navy coats (recommended)"))
        #expect(lines.lines.contains("  2. Green coats"))
        #expect(lines.lines.contains { $0.hasPrefix("Choose a number from 1 to 2") })
        #expect(await reviewer.requests.last?.answers["style"] == "Green coats")
        let markdown = try String(contentsOf: folder.appendingPathComponent("batch-summary.md"), encoding: .utf8)
        #expect(markdown.contains("| style | Which coat colour? | Green coats | stdin |"))
    }

    @Test func answersFileSuppliesChoicesWithoutReadingStdin() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("answers.json")
        try "{\"straighten\":\"Leave them\",\"style\":\"Green coats\"}".write(to: file, atomically: true, encoding: .utf8)
        let command = try Batch.parse(["photos", "Change coats", "--out", folder.path, "--answers", file.path])
        let host = try BatchScriptedLibrary(output: folder, names: ["tilted.png"])
        let input = BatchScriptedInput([])
        let result = try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(question: BatchScriptedReviewer.style),
                                               models: PhotoFixtures.models(), options: command.batchOptions, output: folder,
                                               answers: BatchInput.answers(from: URL(fileURLWithPath: command.answers!)),
                                               input: input.input(), line: { _ in })
        #expect(result.answers.map(\.answer) == ["Leave them", "Green coats"])
        #expect(result.answers.allSatisfy { $0.byPerson })
        #expect(result.photos.first?.straightened == nil)
        #expect(await input.reads == 0)
        let markdown = try String(contentsOf: folder.appendingPathComponent("batch-summary.md"), encoding: .utf8)
        #expect(markdown.contains("| style | Which coat colour? | Green coats | answers file |"))
    }

    @Test func nonTerminalStdinUsesRecommendationsAndRecordsTheirAuthor() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try BatchScriptedLibrary(output: folder, names: ["tilted.png"])
        let input = BatchScriptedInput(["2"])
        let lines = LineRecorder()
        let result = try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(question: BatchScriptedReviewer.style),
                                               models: PhotoFixtures.models(), options: BatchOptions(instruction: "Change coats"),
                                               output: folder, input: input.input(terminal: false), line: lines.append)
        #expect(result.answers.map(\.answer) == ["Straighten them", "Navy coats"])
        #expect(result.answers.allSatisfy { !$0.byPerson })
        #expect(await input.reads == 0)
        #expect(lines.lines.contains("Using recommendation for style: Navy coats (stdin is not a terminal)."))
    }

    @Test(arguments: [[], [""], ["n"]])
    func planRefusalLeavesPhotosAndOutputUntouched(_ replies: [String]) async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        let host = try BatchScriptedLibrary(output: output, names: ["good.png"])
        let input = BatchScriptedInput(replies)
        let lines = LineRecorder()
        await #expect(throws: LumenError.cancelled) {
            try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(), models: PhotoFixtures.models(),
                                      options: BatchOptions(mode: .planFirst, instruction: "Change coats"), output: output,
                                      input: input.input(terminal: false), line: lines.append)
        }
        #expect(await host.auto.isEmpty)
        #expect(await host.saved.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(lines.lines.contains("Go ahead? [y/N]"))
        #expect(lines.lines.contains { $0.hasPrefix("Estimate: About 5 more model calls") })
        #expect(Lumen.exitCode(for: LumenError.cancelled) != .success)
    }

    @Test(arguments: [false, true])
    func planRunsAfterYOrYesFlag(_ approve: Bool) async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try BatchScriptedLibrary(output: folder, names: ["good.png"])
        let input = BatchScriptedInput(["y"])
        let lines = LineRecorder()
        let result = try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(), models: PhotoFixtures.models(),
                                               options: BatchOptions(mode: .planFirst), output: folder, approve: approve,
                                               input: input.input(), line: lines.append)
        #expect(!result.photos[0].failed)
        #expect(await host.auto == [PhotoID("good.png")])
        #expect(await input.reads == (approve ? 0 : 1))
        #expect(lines.lines.contains("Go ahead? [y/N]") == !approve)
    }

    @Test func individualFailuresRemainInSuccessfulBatchSummary() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try BatchScriptedLibrary(output: folder, names: ["good.png", "broken.png", "save-fails.png"])
        let lines = LineRecorder()
        let result = try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(), models: PhotoFixtures.models(),
                                               options: BatchOptions(mode: .autonomous), output: folder,
                                               input: BatchScriptedInput([]).input(), line: lines.append)
        #expect(result.photos.filter(\.failed).map(\.photo.rawValue) == ["broken.png", "save-fails.png"])
        #expect(lines.lines.contains { $0.hasPrefix("Finished: 3 photos, 0 flagged, 2 failed;") })
        let markdown = try String(contentsOf: folder.appendingPathComponent("batch-summary.md"), encoding: .utf8)
        #expect(markdown.contains("Failed: Unreadable photo."))
        #expect(markdown.contains("Failed: Could not save photo."))
    }

    @Test func summaryEscapesPhotoNamesInstructionsAndAnswers() {
        let question = BatchQuestion(id: "style", question: "Navy | green?", options: ["<navy>", "green"], recommended: 0)
        let summary = BatchSummary(photos: [
            BatchPhotoResult(photo: PhotoID("a|b.png"), flagged: "Too <dark>", auto: "Auto: +0.3", straightened: -2,
                             instruction: "Navy\ncoat | green", outcome: "Couldn't save & keep", failed: true),
        ], answers: [BatchAnswer(question: question, answer: "<navy>", byPerson: true)], modelCalls: 4, duration: 2)
        let markdown = BatchReport.markdown(summary)
        #expect(markdown.contains("| a&#124;b.png | Too &lt;dark&gt; | Auto: +0.3 |  |  | -2.0° | Navy coat &#124; green | Failed: Couldn't save &amp; keep |"))
        #expect(markdown.contains("| style | Navy &#124; green? | &lt;navy&gt; | person |"))
    }

    @Test(arguments: [true, false])
    func cancellationStopsReviewAndApprovalPrompts(_ approval: Bool) async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        let host = try BatchScriptedLibrary(output: output, names: ["good.png"])
        let pause = BatchPause()
        let reviewer: any BatchPlanner = approval ? BatchScriptedReviewer() : BatchWaitingReviewer(pause: pause)
        let input = BatchInput(isTerminal: true, read: { try await pause.wait(); return "y" })
        let task = Task {
            try await BatchRunner.run(host: host, reviewer: reviewer, models: PhotoFixtures.models(),
                                      options: BatchOptions(mode: .planFirst), output: output, input: input, line: { _ in })
        }
        await pause.waitUntilEntered()
        task.cancel()
        await #expect(throws: LumenError.cancelled) { try await task.value }
        #expect(await host.auto.isEmpty)
        #expect(await host.saved.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func libraryFailureStopsTheBatch() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        let host = try BatchScriptedLibrary(output: output, failToList: true)
        await #expect(throws: CLIError.self) {
            try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(), models: PhotoFixtures.models(),
                                      options: BatchOptions(), output: output, input: BatchScriptedInput([]).input(), line: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(Lumen.exitCode(for: CLIError("Could not list the library.")) != .success)
    }

    @Test(arguments: [true, false])
    func emptyAndUnchangedLibrariesStillProduceAllReports(_ empty: Bool) async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try BatchScriptedLibrary(output: folder, names: empty ? [] : ["good.png"])
        let planner = ScriptedPlanner()
        let reviewer = BatchScriptedReviewer()
        let result = try await BatchRunner.run(host: host, reviewer: reviewer, models: PhotoFixtures.models(planner: planner),
                                               options: BatchOptions(mode: .autonomous, auto: false, straighten: false, maxModelCalls: 0),
                                               output: folder, input: BatchScriptedInput([]).input(), line: { _ in })
        #expect(result.modelCalls == 0)
        #expect(await planner.requests.isEmpty)
        #expect(await reviewer.requests.isEmpty)
        #expect(await host.saved.count == (empty ? 0 : 1))
        if !empty { #expect(result.photos[0].outcome == "Skipped: model call limit reached.") }
        for filename in BatchReport.filenames {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path))
        }
    }

    @Test func suppliedAnswerOverridesAutomaticRecommendation() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try BatchScriptedLibrary(output: folder, names: ["tilted.png"])
        let input = BatchScriptedInput([])
        let result = try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(), models: PhotoFixtures.models(),
                                               options: BatchOptions(mode: .autonomous), output: folder,
                                               answers: ["straighten": "Leave them"], input: input.input(), line: { _ in })
        #expect(result.answers.first?.answer == "Leave them")
        #expect(result.answers.first?.byPerson == true)
        #expect(result.photos.first?.straightened == nil)
        #expect(await input.reads == 0)
    }

    @Test func invalidAnswerStopsAPlanBeforeChanges() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try BatchScriptedLibrary(output: folder, names: ["tilted.png"])
        await #expect(throws: CLIError.self) {
            try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(), models: PhotoFixtures.models(),
                                      options: BatchOptions(mode: .planFirst), output: folder,
                                      answers: ["straighten": "Maybe"], input: BatchScriptedInput([]).input(), line: { _ in })
        }
        #expect(await host.auto.isEmpty)
        #expect(await host.saved.isEmpty)
    }

    @Test func measurementEventsStayCompactForAThousandPhotos() {
        let photos = (1...1000).map { PhotoID("photo-\($0).jpg") }
        var lines = BatchEventLines(photos: photos)
        #expect(lines.accept(.found(count: 1000)) == ["Found 1000 photos."])
        let facts = PhotoFacts(size: PixelSize(width: 10, height: 10), sharpness: 0.8, exposure: 0.5)
        for photo in photos { #expect(lines.accept(.measured(photo, facts)).isEmpty) }
        #expect(lines.accept(.progress(done: 1, total: 1000)) == ["Measured 1000 of 1000 photos.", "Progress: 1/1000 photos"])
        #expect(lines.accept(.progress(done: 2, total: 1000)) == ["Progress: 2/1000 photos"])
    }

    @Test(.enabled(if: PhotoFixtures.renderingAvailable, "Core Image rendering is unavailable on this host."))
    func folderLibraryExportsUntouchedAndFlaggedPhotosWithSidecars() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        for name in ["good.png", "misfire.png"] { try PhotoFixtures.image().data.write(to: folder.appendingPathComponent(name)) }
        let host = try FolderLibrary(folder: folder, output: output)
        let result = try await BatchRunner.run(host: host, reviewer: BatchScriptedReviewer(), models: PhotoFixtures.models(),
                                               options: BatchOptions(mode: .autonomous, auto: false, straighten: false, qualityThreshold: 0),
                                               output: output, input: BatchScriptedInput([]).input(), line: { _ in })
        #expect(result.photos.count == 2)
        for name in ["good.png", "misfire.png"] {
            #expect(PhotoFixtures.size(of: output.appendingPathComponent(name)) == PixelSize(width: 20, height: 10))
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(name + ".lumen.json").path))
        }
        let sidecar = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("misfire.png.lumen.json"))) as? [String: Any])
        #expect(sidecar["flag"] as? String == "Pocket shot")
    }

    private func centerGray(_ url: URL) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return bytes[((image.height / 2) * image.width + BatchContactSheet.cellWidth / 2) * 4]
    }
}
