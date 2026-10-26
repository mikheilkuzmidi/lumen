import ArgumentParser
import Foundation
import LumenCore
import Testing
@testable import lumen

struct ArgumentsTests {
    @Test func editDefaults() throws {
        let command = try #require(Lumen.parseAsRoot(["edit", "/tmp/portrait.heic", "Make the coat navy"]) as? Edit)
        #expect(command.photo == "/tmp/portrait.heic")
        #expect(command.instruction == "Make the coat navy")
        #expect(command.options.backend == .meta)
        #expect(command.options.area == nil)
        #expect(command.options.maxSteps == 12)
        #expect(command.options.maxRevisions == 2)
        #expect(command.options.preview == 1536)
        #expect(command.outputURL.path == "/tmp/portrait-lumen.jpg")
        #expect(command.traceURL == nil)
    }

    @Test func editOptions() throws {
        let command = try #require(Lumen.parseAsRoot([
            "edit", "photo.jpg", "Change the coat", "--area", "0.1,0.2,0.3,0.4", "--backend", "spark-open",
            "--out", "result.PNG", "--trace", "result.json", "--max-steps", "8", "--max-revisions", "1", "--preview", "512",
        ]) as? Edit)
        #expect(command.options.area == NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(command.options.backend == .sparkOpen)
        #expect(command.outputURL.lastPathComponent == "result.PNG")
        #expect(command.traceURL?.lastPathComponent == "result.json")
        #expect(command.options.agentConfiguration.maxSteps == 8)
        #expect(command.options.agentConfiguration.maxRevisions == 1)
        #expect(command.options.agentConfiguration.previewLongEdge == 512)
    }

    @Test(arguments: [
        ["--backend", "other"], ["--max-steps", "-1"], ["--max-revisions", "-1"], ["--preview", "0"],
        ["--preview", "-1"], ["--max-steps", "1.5"], ["--out", "result.tiff"], ["--out", "photo.jpg"],
        ["--trace", "photo.jpg"], ["--out", "result.png", "--trace", "result.png"],
    ])
    func rejectsInvalidOptions(_ options: [String]) {
        #expect(throws: (any Error).self) { try Lumen.parseAsRoot(["edit", "photo.jpg", "Change the coat"] + options) }
    }

    @Test(arguments: ["", "0,0,1", "0,0,1,1,0", "0,,1,1", "a,0,1,1", "nan,0,1,1", "0,0,inf,1",
                      "-0.1,0,0.5,1", "0,-0.1,1,0.5", "0,0,0,1", "0,0,1,-1", "0.8,0,0.3,1", "0,0.9,1,0.2"])
    func rejectsInvalidAreas(_ area: String) {
        #expect(throws: (any Error).self) { try parseArea(area) }
        #expect(throws: (any Error).self) { try Lumen.parseAsRoot(["edit", "photo.jpg", "Change it", "--area=\(area)"]) }
    }

    @Test func acceptsAreasOnTheEdges() throws {
        #expect(try parseArea("0,0,1,1") == .whole)
        #expect(try parseArea(" 0.5, 0.25, 0.5, 0.75 ") == NormalizedRect(x: 0.5, y: 0.25, width: 0.5, height: 0.75))
        let command = try Edit.parse(["photo.jpg", "Change it", "--max-steps", "0", "--max-revisions", "0"])
        #expect(command.options.maxSteps == 0)
    }

    @Test func evaluationOptions() throws {
        let command = try #require(Lumen.parseAsRoot([
            "eval", "cases.json", "--out", "results", "--only", "coat", "--dry-run", "--backend", "glimmer",
        ]) as? Evaluate)
        #expect(command.cases == "cases.json")
        #expect(command.out == "results")
        #expect(command.only == "coat")
        #expect(command.dryRun)
        #expect(command.options.backend == .glimmer)
        #expect(throws: (any Error).self) { try Lumen.parseAsRoot(["eval", "cases.json"]) }
    }

    @Test func backendsReportTheirOwnErrorsWithoutCallingModels() {
        #expect(throws: LumenError.missingKey) { try Backend.meta.models(environment: [:]) }
        #expect(throws: LumenError.missingKey) { try Backend.meta.models(environment: ["META_API_KEY": " \n"]) }
        #expect(throws: LumenError.notBuilt("Local Muse Glimmer planning")) { try Backend.glimmer.models(environment: [:]) }
        #expect(throws: LumenError.notBuilt("Muse Spark Open planning")) { try Backend.sparkOpen.models(environment: [:]) }
        #expect(Lumen.message(for: LumenError.missingKey) == LumenError.missingKey.localizedDescription)
        #expect(Lumen.exitCode(for: LumenError.missingKey) != .success)
    }

    @Test func outputCannotAliasTheOriginalThroughASymlink() throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.png")
        let alias = folder.appendingPathComponent("alias.png")
        try PhotoFixtures.image().data.write(to: photo)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: photo)
        #expect(throws: (any Error).self) { try PhotoOutput.validate(photo: photo, output: alias, trace: nil) }
    }
}
