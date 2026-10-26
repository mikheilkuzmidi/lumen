import Foundation
import Testing
@testable import LumenCore

@Suite("Edit plan")
struct EditPlanTests {
    @Test func stepsAreFlatObjectsWithATypeField() throws {
        let plan = EditPlan(summary: "Moodier sky, blue coat", steps: [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: -0.4, .saturation: 10])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy blue wool coat")),
            .finish(Finish(reason: "Both changes are in.")),
        ])
        let data = try JSONEncoder().encode(plan)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let steps = try #require(object?["steps"] as? [[String: Any]])
        #expect(steps.map { $0["type"] as? String } == ["select", "adjust", "regenerate", "finish"])
        #expect(steps[0]["concept"] as? String == "sky" && steps[2]["prompt"] as? String == "a navy blue wool coat")
        #expect((steps[1]["values"] as? [String: Double])?["exposure"] == -0.4, "adjustments are keyed by name")
        #expect(try JSONDecoder().decode(EditPlan.self, from: data) == plan)
    }

    @Test func anUnknownStepTypeIsRefused() {
        let json = Data(#"{"summary":"x","steps":[{"type":"teleport"}]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditPlan.self, from: json) }
    }

    @Test func maskAreaIsTheShareCovered() {
        var coverage = [UInt8](repeating: 0, count: 100)
        for i in 0..<25 { coverage[i] = 255 }
        #expect(MaskData(size: PixelSize(width: 10, height: 10), coverage: coverage).area == 0.25)
        #expect(MaskData(size: PixelSize(width: 4, height: 4), filledWith: 255).area == 1)
    }
}
