import Testing
@testable import LumenCore

/// Four friends in a row: when SAM finds several shirts, the planner's point or box says which one is meant.
struct SelectionChoiceTests {
    private func shirt(_ column: Int) -> Segment {
        var coverage = [UInt8](repeating: 0, count: 40 * 10)
        for y in 4..<9 { for x in (column * 10 + 2)..<(column * 10 + 8) { coverage[y * 40 + x] = 255 } }
        let mask = MaskData(size: PixelSize(width: 40, height: 10), coverage: coverage)
        return Segment(label: "shirt", box: mask.boundingBox!, mask: mask)
    }

    @Test func aPointPicksTheShirtUnderIt() {
        let shirts = (0..<3).map(shirt)
        let meant = EditAgent.meant(shirts, points: [NormalizedPoint(x: 0.62, y: 0.6)], box: nil)
        #expect(meant.map(\.box) == [shirts[2].box])
    }

    @Test func withoutAPointTheBoxThatFitsBestWins() {
        let shirts = (0..<3).map(shirt)
        let box = NormalizedRect(x: 0.25, y: 0.35, width: 0.25, height: 0.6)
        #expect(EditAgent.meant(shirts, points: [], box: box).map(\.box) == [shirts[1].box])
        // A point that misses every shirt leaves the box to decide.
        #expect(EditAgent.meant(shirts, points: [NormalizedPoint(x: 0.3, y: 0.1)], box: box).map(\.box) == [shirts[1].box])
    }

    @Test func aBoxOverAShirtSAMDidNotFindKeepsNone() {
        // SAM found the first three shirts by name but not the fourth, which the box is around.
        let shirts = (0..<3).map(shirt)
        let fourth = NormalizedRect(x: 0.77, y: 0.35, width: 0.2, height: 0.6)
        #expect(EditAgent.meant(shirts, points: [], box: fourth).isEmpty)
    }
}
