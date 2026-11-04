import Foundation
import LumenCore
import Testing
@testable import LumenUI

@Suite("Live edit view")
struct LiveEditTests {
    private func disk(width: Int = 400, height: Int = 300) -> Segment {
        var coverage = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width where hypot(Double(x - 200), Double(y - 150)) < 80 { coverage[y * width + x] = 255 } }
        return Segment(label: "jacket", box: NormalizedRect(x: 0.3, y: 0.23, width: 0.4, height: 0.54),
                       mask: MaskData(size: PixelSize(width: width, height: height), coverage: coverage))
    }

    @Test func aRecolourMovesFromReadingToFindingToRedrawingToChecking() {
        var state = LiveEditState()
        #expect(state.phase == nil)
        state.begin()
        #expect(state.phase == .reading)
        #expect(state.label == "Muse Spark · reading the instruction")
        let select = EditStep.select(Selection(id: "jacket", concept: "jacket"))
        let redraw = EditStep.regenerate(Regeneration(region: "jacket", prompt: "a bright yellow jacket"))
        state.receive(.planned(EditPlan(summary: "Yellow jacket", steps: [select, redraw, .finish(Finish(reason: "Done"))])))
        #expect(state.phase == .reading)
        state.receive(.stepStarted(index: 0, step: select))
        #expect(state.phase == .finding)
        #expect(state.label == "SAM 3.1 · finding the jacket")
        state.receive(.selected(region: "jacket", segment: disk()))
        #expect(state.phase == .found)
        #expect(state.mask != nil)
        #expect(state.label == "SAM 3.1 · jacket")
        let revision = state.maskRevision
        state.receive(.stepStarted(index: 1, step: redraw))
        #expect(state.phase == .generating)
        #expect(state.maskRevision == revision)
        #expect(state.label == "Muse Image · redrawing the jacket")
        let layer = Layer(label: "Jacket", content: .adjustment(values: [:], mask: nil))
        state.receive(.applied(layer))
        #expect(state.phase == .checking)
        #expect(state.label == "Checking with SAM 3.1 and Muse Spark")
        state.receive(.critiqued(Critique(satisfied: true, notes: "Yellow")))
        #expect(state.phase == .accepted)
        state.receive(.finished(reason: "Done"))
        #expect(state.phase == .accepted)
        state.end()
        #expect(state.phase == nil)
    }

    @Test func anAdjustmentNeverShowsARedraw() {
        var state = LiveEditState()
        state.begin()
        let select = EditStep.select(Selection(id: "sky", concept: "the sky"))
        state.receive(.stepStarted(index: 0, step: select))
        state.receive(.selected(region: "sky", segment: disk()))
        state.receive(.stepStarted(index: 1, step: .adjust(Adjustment(region: "sky", values: [.exposure: -0.3]))))
        #expect(state.phase == .adjusting)
        #expect(state.label == "Adjusting the jacket")
        state.receive(.stepStarted(index: 2, step: .adjust(Adjustment(values: [.contrast: 0.1]))))
        #expect(state.phase == .adjusting)
        #expect(state.mask == nil)
        #expect(state.label == "Adjusting the photo")
    }

    @Test func aFailureOrAnUnacceptedFinishClearsTheView() {
        var state = LiveEditState(models: LiveEditModels(planner: "Muse Glimmer"))
        state.begin()
        #expect(state.label == "Muse Glimmer · reading the instruction")
        state.receive(.trace(TraceEvent(kind: .failure, detail: "No network", started: Date(), duration: 0)))
        #expect(state.phase == nil)
        state.receive(.stepStarted(index: 0, step: .select(Selection(id: "cup"))))
        #expect(state.phase == nil)
        state.begin()
        state.receive(.finished(reason: "Nothing to do"))
        #expect(state.phase == nil)
    }

    @Test func aCriticsRevisionGoesBackToThePlanner() {
        var state = LiveEditState()
        state.begin()
        state.receive(.applied(Layer(label: "Sky", content: .adjustment(values: [:], mask: nil))))
        state.receive(.critiqued(Critique(satisfied: false, notes: "Too dark", steps: [.adjust(Adjustment(values: [.exposure: 0.2]))])))
        #expect(state.phase == .reading)
        #expect(state.label == "Muse Spark · revising the plan")
    }

    @Test func aMaskBecomesAFillAnEdgeAndABox() throws {
        let segment = disk()
        let art = try #require(LiveEditMask(mask: segment.mask, maxLongEdge: 200))
        #expect(art.fill.width == 200 && art.fill.height == 150)
        #expect(art.edge.width == 200)
        #expect(abs(art.box.x - 0.3) < 0.03 && abs(art.box.width - 0.4) < 0.03)
        #expect(abs(art.box.y - 0.233) < 0.03 && abs(art.box.height - 0.533) < 0.03)
        let alpha = try #require(art.edge.dataProvider?.data as Data?)
        let edgePixels = stride(from: 3, to: alpha.count, by: 4).filter { alpha[$0] > 128 }.count
        let fillAlpha = try #require(art.fill.dataProvider?.data as Data?)
        let fillPixels = stride(from: 3, to: fillAlpha.count, by: 4).filter { fillAlpha[$0] > 128 }.count
        #expect(edgePixels > 100 && edgePixels < fillPixels / 4)
        let empty = MaskData(size: PixelSize(width: 10, height: 10), coverage: [UInt8](repeating: 0, count: 100))
        #expect(LiveEditMask(mask: empty) == nil)
    }

    @Test func namesReadNaturally() {
        #expect(LiveEditState.named("jacket") == "the jacket")
        #expect(LiveEditState.named("his jacket") == "his jacket")
        #expect(LiveEditState.named("The sky") == "The sky")
    }
}
