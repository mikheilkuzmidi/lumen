import Foundation
import LumenCore
import Testing
@testable import lumen

struct EditTests {
    @Test(.enabled(if: PhotoFixtures.renderingAvailable, "Core Image rendering is unavailable on this host."))
    func scriptedEditPrintsEventsAndWritesFullSizePhotoAndTrace() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.png")
        let output = folder.appendingPathComponent("result.png")
        let traceURL = folder.appendingPathComponent("result.trace.json")
        let original = try PhotoFixtures.image()
        try original.data.write(to: photo)
        let lines = LineRecorder()
        let planner = ScriptedPlanner()
        var options = try PhotoFixtures.options()
        options.area = try parseArea("0,0,1,0.5")
        let result = try await EditRunner.run(photo: photo, instruction: "Make the coat navy", options: options,
                                              models: PhotoFixtures.models(planner: planner), output: output, trace: traceURL,
                                              line: lines.append)
        #expect(result.failure == nil)
        #expect(result.exported)
        #expect(result.stepsApplied == 1)
        #expect(result.modelCalls == 4)
        #expect(result.events.map(\.kind) == [.plan, .select, .regenerate, .critique, .finish])
        #expect(try Data(contentsOf: photo) == original.data)
        #expect(PhotoFixtures.size(of: output) == original.size)
        #expect(try Data(contentsOf: output).starts(with: [137, 80, 78, 71]))
        #expect(await planner.requests.first?.image.size.longEdge == 10)
        #expect(await planner.requests.first?.area == options.area)
        #expect(lines.lines.map { $0.replacingOccurrences(of: #"\d+\.\d s"#, with: "<time>", options: .regularExpression) } == [
            "Plan: Make the coat navy.",
            "→ select coat (SAM 3.1, <time>): 1 region, 18% of the photo",
            "→ redraw coat (Muse Image, <time>)",
            "Critique: satisfied: The coat is navy.",
            "Finished: The coat is navy.",
        ])
        #expect(lines.lines.allSatisfy { !$0.contains("\u{001B}") })
        let data = try Data(contentsOf: traceURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["instruction"] as? String == "Make the coat navy")
        #expect(object["backend"] as? String == "meta")
        #expect(object["modelIDs"] as? [String: String] == ["planner": "muse-spark-1.3", "segmenter": "sam-3.1", "generator": "muse-image-1.0"])
        #expect((object["events"] as? [[String: Any]])?.count == 5)
        #expect((object["plans"] as? [[String: Any]])?.count == 1)
        #expect(object["layerLabels"] as? [String] == ["Coat: redrawn as A navy coat"])
        #expect((object["totalTime"] as? Double ?? -1) >= 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EditTrace.self, from: data)
        #expect(decoded.plans == result.plans)
        #expect(decoded.events.map(\.detail) == result.events.map(\.detail))
        #expect(decoded.critiques == result.critiques)
    }

    @Test func revisionsRetainCheckedPlansAndFinalVerdict() async throws {
        let planner = ScriptedPlanner(critiques: [
            Critique(satisfied: false, notes: "Needs more contrast", steps: [.adjust(Adjustment(region: "coat", values: [.contrast: 200]))]),
            Critique(satisfied: true, notes: "Looks right."),
        ])
        let result = await EditRunner.run(host: try ScriptedPhoto(), instruction: "Change the coat", options: try PhotoFixtures.options(),
                                          models: PhotoFixtures.models(planner: planner), line: { _ in })
        #expect(result.failure == nil)
        try #require(result.plans.count == 2)
        #expect(result.plans[1].steps == [.adjust(Adjustment(region: "coat", values: [.contrast: 100]))])
        #expect(result.revisions == 1)
        #expect(result.stepsApplied == 2)
        #expect(result.verdict == "Satisfied")
        #expect(result.modelCalls == 5)
    }

    @Test func eventLinesUseMeasuredTimesAndKeepEachEventOnOneLine() {
        var lines = EventLines()
        let started = Date(timeIntervalSince1970: 0)
        _ = lines.accept(.stepStarted(index: 0, step: .select(Selection(id: "coat", concept: "coat"))))
        _ = lines.accept(.trace(TraceEvent(kind: .select, model: "sam-3.1", detail: "coat", started: started, duration: 1.6)))
        let mask = MaskData(size: PixelSize(width: 10, height: 10), coverage: [UInt8](repeating: 255, count: 18) + [UInt8](repeating: 0, count: 82))
        #expect(lines.accept(.selected(region: "coat", segment: Segment(label: "coat", box: .whole, mask: mask)))
                == "→ select coat (SAM 3.1, 1.6 s): 1 region, 18% of the photo")
        _ = lines.accept(.stepStarted(index: 1, step: .regenerate(Regeneration(region: "coat", prompt: "navy"))))
        _ = lines.accept(.trace(TraceEvent(kind: .regenerate, model: "muse-image-1.0", detail: "navy", started: started, duration: 14.2)))
        #expect(lines.accept(.applied(Layer(label: "Coat", content: .crop(.whole)))) == "→ redraw coat (Muse Image, 14.2 s)")
        #expect(lines.accept(.critiqued(Critique(satisfied: false, notes: "Too bright.\nTry again."))) == "Critique: needs revision: Too bright. Try again.")
        #expect(lines.accept(.finished(reason: "Revision limit reached.")) == "Finished: Revision limit reached.")
    }
}
