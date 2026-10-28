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
        // A point that misses every shirt means SAM missed the one meant: nothing is kept, so the point and box
        // become SAM's own prompt.
        #expect(EditAgent.meant(shirts, points: [NormalizedPoint(x: 0.3, y: 0.1)], box: box).isEmpty)
    }

    @Test func aBoxOverAShirtSAMDidNotFindKeepsNone() {
        // SAM found the first three shirts by name but not the fourth, which the box is around.
        let shirts = (0..<3).map(shirt)
        let fourth = NormalizedRect(x: 0.77, y: 0.35, width: 0.2, height: 0.6)
        #expect(EditAgent.meant(shirts, points: [], box: fourth).isEmpty)
    }

    @Test func aRedrawIsCheckedWithoutItsOldColour() {
        #expect(EditAgent.withoutColour("white t-shirt") == "t-shirt")
        #expect(EditAgent.withoutColour("Light Grey hoodie") == "hoodie")
        #expect(EditAgent.withoutColour("red gate") == "gate")
        #expect(EditAgent.withoutColour("blue") == nil)
        #expect(EditAgent.withoutColour("sofa") == "sofa")
    }

    @Test func aPointThatMissesAThingByAHairKeepsItButNotANeighbour() {
        // The black-and-white street: the planner's point lay 0.001 of the photo right of the car's box.
        func thing(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Segment {
            Segment(label: "car", box: NormalizedRect(x: x, y: y, width: w, height: h), mask: MaskData(size: PixelSize(width: 1, height: 1), filledWith: 255))
        }
        let cars = [thing(0.502, 0.502, 0.03, 0.019), thing(0.451, 0.501, 0.037, 0.021), thing(0.432, 0.523, 0.117, 0.058)]
        #expect(EditAgent.nearest(cars, points: [NormalizedPoint(x: 0.55, y: 0.578)], box: nil)?.box == cars[2].box)
        // The fourth friend's shirt SAM didn't find: the box is around it, and the third shirt is too far to be meant.
        let shirts = (0..<3).map(shirt)
        #expect(EditAgent.nearest(shirts, points: [], box: NormalizedRect(x: 0.75, y: 0.35, width: 0.25, height: 0.6)) == nil)
        // Two equally near: neither.
        #expect(EditAgent.nearest([thing(0.4, 0.4, 0.1, 0.1), thing(0.52, 0.4, 0.1, 0.1)], points: [NormalizedPoint(x: 0.51, y: 0.45)], box: nil) == nil)
    }
}
