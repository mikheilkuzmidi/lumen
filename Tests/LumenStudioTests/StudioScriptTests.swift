import Foundation
import LumenCore
import Testing
@testable import LumenStudio

@Suite("Studio scripts")
struct StudioScriptTests {
    @Test func parsesTheDocumentedScript() throws {
        let script = try StudioScript.parse(Data(Self.json.utf8))
        #expect(script.photo == "photos/jacket.jpg")
        #expect(script.instruction == "Make the jacket yellow")
        #expect(script.backend == .meta)
        #expect(script.area == NormalizedRect(x: 0.2, y: 0.1, width: 0.4, height: 0.7))
        #expect(script.window == StudioScript.Window(width: 1440, height: 900))
        #expect(script.photoURL(relativeTo: URL(fileURLWithPath: "/tmp/edit/run.json")).path == "/tmp/edit/photos/jacket.jpg")
    }

    @Test func acceptsNullAndMissingAreas() throws {
        for area in ["\"area\": null,", ""] {
            let script = try StudioScript.parse(Data(Self.json.replacingOccurrences(of: Self.area, with: area).utf8))
            #expect(script.area == nil)
        }
    }

    @Test(arguments: [
        ("\"meta\"", "\"local\""),
        ("photos/jacket.jpg", "  "),
        ("Make the jacket yellow", "  "),
        ("1440", "0"),
        ("900", "-1"),
        ("1440", "9000"),
        ("\"x\": 0.2", "\"x\": -0.2"),
        ("\"width\": 0.4", "\"width\": 0"),
        ("\"height\": 0.7", "\"height\": 1"),
    ])
    func rejectsInvalidScripts(replacement: (String, String)) {
        let json = Self.json.replacingOccurrences(of: replacement.0, with: replacement.1)
        #expect(throws: (any Error).self) { try StudioScript.parse(Data(json.utf8)) }
    }

    @Test(arguments: ["{}", "{", "null", "[]"])
    func rejectsIncompleteJSON(json: String) {
        #expect(throws: (any Error).self) { try StudioScript.parse(Data(json.utf8)) }
    }

    @Test func parsesArgumentsInEitherOrder() throws {
        let first = try StudioScriptArguments(["--script", "/tmp/run.json", "--out", "/tmp/results"])
        let second = try StudioScriptArguments(["--out", "/tmp/results", "--script", "/tmp/run.json"])
        #expect(first == second)
        #expect(first.script.path == "/tmp/run.json")
        #expect(first.output.path == "/tmp/results")
    }

    @Test(arguments: [[], ["--script"], ["--out", "/tmp/results"],
                      ["--script", "--out", "/tmp/results"],
                      ["--script", "a", "--out", "b", "--script", "c"],
                      ["--script", "a", "--out", "b", "--unknown", "c"]])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: (any Error).self) { try StudioScriptArguments(arguments) }
    }

    @Test func findsErrorOutputForInvalidArguments() {
        #expect(StudioScriptArguments.errorOutput(in: ["--unknown", "x", "--out", "/tmp/results"])?.path == "/tmp/results")
        #expect(StudioScriptArguments.errorOutput(in: ["--out"]) == nil)
        #expect(StudioScriptArguments.errorOutput(in: ["--out", "--script"]) == nil)
    }

    @Test func snapshotNamesStayStableAndOrdered() {
        #expect(StudioSnapshot.allCases.map(\.filename) == [
            "1-opened.png", "2-area.png", "3-planned.png", "4-selected.png",
            "5-redrawn.png", "6-finished.png", "7-compare.png", "8-layers.png",
        ])
    }

    @Test func capturesOnlyTheFirstMatchingMilestone() {
        var snapshots = StudioSnapshots()
        let plan = EditPlan(summary: "Change the jacket", steps: [])
        let segment = Segment(label: "jacket", box: .whole, mask: MaskData(size: PixelSize(width: 1, height: 1), filledWith: 255))
        let adjustment = Layer(label: "Light", content: .adjustment(values: [.exposure: 0.2], mask: nil))
        let patch = Layer(label: "Jacket", content: .patch(image: AssetID(), mask: AssetID(), rect: .whole))
        #expect(snapshots.take(for: .planned(plan)) == .planned)
        #expect(snapshots.take(for: .planned(plan)) == nil)
        #expect(snapshots.take(for: .selected(region: "jacket", segment: segment)) == .selected)
        #expect(snapshots.take(for: .selected(region: "jacket", segment: segment)) == nil)
        #expect(snapshots.take(for: .applied(adjustment)) == nil)
        #expect(snapshots.take(for: .applied(patch)) == .redrawn)
        #expect(snapshots.take(for: .applied(patch)) == nil)
        #expect(snapshots.take(for: .finished(reason: "Done")) == .finished)
        #expect(snapshots.take(for: .finished(reason: "Done")) == nil)
    }

    static let area = "\"area\": {\"x\": 0.2, \"y\": 0.1, \"width\": 0.4, \"height\": 0.7},"
    static let json = """
    {"photo": "photos/jacket.jpg", \(area) "instruction": "Make the jacket yellow",
     "backend": "meta", "window": {"width": 1440, "height": 900}}
    """
}
