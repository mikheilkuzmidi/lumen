import Foundation
import LumenCore
import Testing
@testable import lumen

struct EvaluationTests {
    @Test func dryRunListsTwoCasesAndConditionalCallsWithoutOpeningPhotos() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cases.json")
        try """
        {"cases":[
          {"photo":"photos/coat.jpg","instruction":"Make the coat navy"},
          {"photo":"photos/sky.jpg","instruction":"Darken the sky"}
        ]}
        """.write(to: file, atomically: true, encoding: .utf8)
        let output = folder.appendingPathComponent("results")
        let command = try #require(Lumen.parseAsRoot(["eval", file.path, "--out", output.path, "--dry-run"]) as? Evaluate)
        let cases = try EvaluationCases.load(file)
        #expect(cases.map(\.name) == ["coat", "sky"])
        #expect(cases[0].photo == folder.appendingPathComponent("photos/coat.jpg"))
        let lines = EvaluationRunner.dryRun(cases, options: command.options)
        #expect(lines.count == 6)
        #expect(lines[0].hasPrefix("coat: Make the coat navy"))
        #expect(lines[3].hasPrefix("sky: Darken the sky"))
        #expect(lines[1].contains("muse-spark-1.3"))
        #expect(lines[1].contains("sam-3.1"))
        #expect(lines[1].contains("muse-image-1.0"))
        #expect(lines[2].contains("Exact calls depend on"))
        try await command.run()
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try EvaluationCases.load(file, only: "sky").map(\.name) == ["sky"])
        #expect(throws: (any Error).self) { try EvaluationCases.load(file, only: "missing") }
    }

    @Test(.enabled(if: PhotoFixtures.renderingAvailable, "Core Image rendering is unavailable on this host."))
    func evaluationWritesComparisonsTracesAndSummaryAndContinuesAfterFailure() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cases.json")
        let output = folder.appendingPathComponent("results")
        let photo = folder.appendingPathComponent("photo.png")
        try PhotoFixtures.image().data.write(to: photo)
        try """
        {"cases":[
          {"name":"first","photo":"photo.png","instruction":"Cannot edit"},
          {"name":"second","photo":"photo.png","instruction":"Navy | coat"}
        ]}
        """.write(to: file, atomically: true, encoding: .utf8)
        let cases = try EvaluationCases.load(file)
        let planner = ScriptedPlanner(failingInstruction: "Cannot edit")
        let lines = LineRecorder()
        let failures = try await EvaluationRunner.run(cases, file: file, folder: output, options: PhotoFixtures.options(),
                                                       models: PhotoFixtures.models(planner: planner), line: lines.append)
        #expect(failures == 1)
        #expect(await planner.requests.map(\.instruction) == ["Cannot edit", "Navy | coat"])
        for name in ["first", "second"] {
            #expect(PhotoFixtures.size(of: output.appendingPathComponent(name + ".jpg")) == PixelSize(width: 20, height: 10))
            #expect(PhotoFixtures.size(of: output.appendingPathComponent(name + ".compare.jpg"))?.width == 1600)
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(name + ".trace.json").path))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let failed = try decoder.decode(EditTrace.self, from: Data(contentsOf: output.appendingPathComponent("first.trace.json")))
        #expect(failed.failure == LumenError.refused("Cannot edit this photo.").localizedDescription)
        #expect(failed.modelCalls == 1)
        #expect(failed.events.contains { $0.kind == .failure })
        let summary = try String(contentsOf: output.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary.contains("| Judged |"))
        #expect(summary.contains("| Plan | Select | Redraw | Critique | Model calls |"))
        #expect(summary.contains("| first | Cannot edit | 0 | 0 | Not critiqued |"))
        #expect(summary.contains("| second | Navy &#124; coat | 1 | 0 | Satisfied |"))
        #expect(summary.contains("The model declined: Cannot edit this photo."))
        #expect(summary.components(separatedBy: "\n").filter { $0.hasPrefix("| first") || $0.hasPrefix("| second") }.allSatisfy { $0.hasSuffix(" |  |") })
    }

    @Test func caseNamesAreSafeAndRepeatedPhotosGetDistinctNames() throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cases.json")
        try """
        {"cases":[{"photo":"coat.jpg","instruction":"Navy"},{"photo":"coat.png","instruction":"Green"}]}
        """.write(to: file, atomically: true, encoding: .utf8)
        #expect(try EvaluationCases.load(file).map(\.name) == ["coat", "coat-2"])
        try """
        {"cases":[{"name":"../coat","photo":"coat.jpg","instruction":"Navy"}]}
        """.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try EvaluationCases.load(file) }
    }

    @Test func unreadableCasesStillWriteTracesAndSummaryRows() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cases.json")
        let output = folder.appendingPathComponent("results")
        let cases = ["first", "second"].map {
            EvaluationCase(name: $0, photo: folder.appendingPathComponent($0 + ".jpg"), instruction: "Change \($0)")
        }
        let planner = ScriptedPlanner()
        let failures = try await EvaluationRunner.run(cases, file: file, folder: output, options: PhotoFixtures.options(),
                                                       models: PhotoFixtures.models(planner: planner), line: { _ in })
        #expect(failures == 2)
        #expect(await planner.requests.isEmpty)
        for item in cases {
            let data = try Data(contentsOf: output.appendingPathComponent(item.name + ".trace.json"))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["failure"] as? String == LumenError.invalidResponse("The photo could not be opened.").localizedDescription)
        }
        let summary = try String(contentsOf: output.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary.contains("| first | Change first |"))
        #expect(summary.contains("| second | Change second |"))
    }

    @Test func evaluationCannotOverwriteSourcePhotos() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cases.json")
        let photo = folder.appendingPathComponent("coat.jpg")
        let image = try PhotoFixtures.image()
        try image.data.write(to: photo)
        let item = EvaluationCase(name: "coat", photo: photo, instruction: "Navy")
        await #expect(throws: (any Error).self) {
            try await EvaluationRunner.run([item], file: file, folder: folder, options: PhotoFixtures.options(),
                                            models: PhotoFixtures.models(), line: { _ in })
        }
        #expect(try Data(contentsOf: photo) == image.data)
    }
}
