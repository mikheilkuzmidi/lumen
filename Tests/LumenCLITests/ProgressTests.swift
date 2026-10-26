import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import Testing
@testable import lumen

struct ProgressTests {
    @Test func scriptedRunRetainsEventsAndWritesTraceWithoutRendering() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try ScriptedPhoto()
        let lines = LineRecorder()
        let result = await EditRunner.run(host: host, instruction: "Make the coat navy", options: try PhotoFixtures.options(),
                                          models: PhotoFixtures.models(), line: lines.append)
        #expect(result.failure == nil)
        #expect(result.events.map(\.kind) == [.plan, .select, .regenerate, .select, .critique, .finish])
        #expect(result.modelCalls == 5)
        #expect(result.layerLabels == ["Coat: redrawn as A navy coat"])
        #expect(await host.layers.map(\.label) == result.layerLabels)
        #expect(lines.lines.count == 5)
        #expect(lines.lines[0] == "Plan: Make the coat navy.")
        #expect(lines.lines[1].contains("1 region, 40% of the photo"))
        #expect(lines.lines[2].hasPrefix("→ redraw coat (Muse Image, "))
        #expect(lines.lines[3] == "Critique: satisfied: The coat is navy.")
        #expect(lines.lines[4] == "Finished: The coat is navy.")
        let file = folder.appendingPathComponent("trace.json")
        try result.write(to: file)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(object.keys).isSuperset(of: ["instruction", "backend", "modelIDs", "events", "plans", "critiques", "layerLabels", "totalTime"]))
        let events = try #require(object["events"] as? [[String: Any]])
        #expect(events.count == result.events.count)
        #expect(events.allSatisfy { Set($0.keys).isSuperset(of: ["kind", "detail", "started", "duration"]) })
        #expect(events[0]["model"] as? String == "muse-spark-1.3")
        #expect(events[0]["started"] is String)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let trace = try decoder.decode(EditTrace.self, from: Data(contentsOf: file))
        #expect(trace.plans == result.plans)
        #expect(trace.critiques == result.critiques)
    }

    @Test func stepFailureRemainsVisibleEvenWhenTheAgentContinues() async throws {
        let lines = LineRecorder()
        let models = EditModels(planner: ScriptedPlanner(), segmenter: ScriptedSegmenter(), generator: RefusingGenerator())
        let result = await EditRunner.run(host: try ScriptedPhoto(), instruction: "Navy", options: try PhotoFixtures.options(),
                                          models: models, line: lines.append)
        #expect(result.failure == LumenError.refused("Cannot redraw.").localizedDescription)
        #expect(result.events.contains { $0.kind == .failure })
        #expect(result.modelCalls == 4)
        #expect(result.layerLabels.isEmpty)
        #expect(lines.lines.contains { $0.hasPrefix("Failed:") })
    }

    @Test func zeroStepRunMakesNoCalls() async throws {
        var options = try PhotoFixtures.options()
        options.maxSteps = 0
        let planner = ScriptedPlanner()
        let result = await EditRunner.run(host: try ScriptedPhoto(), instruction: "Navy", options: options,
                                          models: PhotoFixtures.models(planner: planner), line: { _ in })
        #expect(result.modelCalls == 0)
        #expect(await planner.requests.isEmpty)
        #expect(result.finalReason == "Step limit reached.")
        #expect(EvaluationRunner.dryRun([EvaluationCase(name: "coat", photo: URL(fileURLWithPath: "/coat.jpg"), instruction: "Navy")],
                                       options: options).last == "  No model calls (--max-steps 0).")
    }

    @Test func cancellationStopsTheActivePlanner() async throws {
        let planner = WaitingPlanner()
        let host = try ScriptedPhoto()
        let options = try PhotoFixtures.options()
        let task = Task {
            try await withInterruptCancellation {
                await EditRunner.run(host: host, instruction: "Navy", options: options,
                                     models: PhotoFixtures.models(planner: planner), line: { _ in })
            }
        }
        await planner.waitUntilEntered()
        task.cancel()
        let result = try await task.value
        #expect(result.failure == LumenError.cancelled.localizedDescription)
        #expect(await host.layers.isEmpty)
    }

    @Test func summaryTotalsIncludeFailedCallsAndRemovalTime() {
        let ids = ModelIDs(planner: "planner", segmenter: "segmenter", generator: "generator")
        var trace = EditTrace(instruction: "Navy | coat", backend: .meta, modelIDs: ids)
        trace.stepsApplied = 2
        trace.revisions = 1
        trace.critiques = [Critique(satisfied: false, notes: "Still too bright")]
        trace.failure = "Rate limited"
        let stages: [(TraceEvent.Kind, TimeInterval)] = [(.plan, 1), (.select, 2), (.regenerate, 3), (.remove, 4), (.critique, 5)]
        trace.events = stages.map {
            TraceEvent(kind: $0.0, model: "model", detail: "stage", started: Date(), duration: $0.1)
        }
        trace.events.append(TraceEvent(kind: .failure, detail: "Rate limited", started: Date(), duration: 0))
        let item = EvaluationCase(name: "coat", photo: URL(fileURLWithPath: "/coat.jpg"), instruction: trace.instruction)
        #expect(EvaluationRunner.markdown([(item, trace)]).contains(
            "| coat | Navy &#124; coat | 2 | 1 | Needs revision | 1.0 s | 2.0 s | 7.0 s | 5.0 s | 5 | Rate limited |  |"))
    }

    @Test func comparisonKeepsBeforeOnTheLeftAndAfterOnTheRight() async throws {
        let folder = try PhotoFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = folder.appendingPathComponent("before.png")
        let after = folder.appendingPathComponent("after.png")
        let output = folder.appendingPathComponent("compare.jpg")
        try PhotoFixtures.image(gray: 0.1).data.write(to: before)
        try PhotoFixtures.image(size: PixelSize(width: 10, height: 20), gray: 0.8).data.write(to: after)
        try await PhotoComparison.write(before: before, after: after, to: output)
        #expect(PhotoFixtures.size(of: output) == PixelSize(width: 1600, height: 1600))
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: 1600, height: 1600, bitsPerComponent: 8, bytesPerRow: 1600 * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1600, height: 1600))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[(800 * 1600 + 400) * 4] < 80)
        #expect(bytes[(800 * 1600 + 1200) * 4] > 160)
    }
}

private struct RefusingGenerator: Generator {
    let modelID = "muse-image-1.0"
    func generate(_ request: GenerateRequest) async throws -> EncodedImage { throw LumenError.refused("Cannot redraw.") }
}

private actor WaitingPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        entered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        try await Task.sleep(for: .seconds(60))
        return EditPlan(summary: "Unused", steps: [])
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Unused") }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
}
