import Testing
@testable import LumenCore

@Suite("Mask overlap")
struct MaskOverlapTests {
    @Test func overlapMeasuresSharedArea() {
        let size = PixelSize(width: 4, height: 1)
        let original = MaskData(size: size, coverage: [255, 255, 0, 0])
        let moved = MaskData(size: size, coverage: [0, 255, 255, 0])
        #expect(original.intersectionOverUnion(original) == 1)
        #expect(abs(original.intersectionOverUnion(moved) - 1.0 / 3) < 0.000001)
        #expect(original.intersectionOverUnion(MaskData(size: size, coverage: [0, 0, 255, 255])) == 0)
    }

    @Test func overlapUsesSoftCoverageAndACommonSize() {
        let original = MaskData(size: PixelSize(width: 2, height: 2), filledWith: 128)
        let smaller = MaskData(size: PixelSize(width: 1, height: 1), filledWith: 255)
        #expect(original.intersectionOverUnion(smaller) == 128.0 / 255)
        #expect(original.intersectionOverUnion(MaskData(size: original.size, filledWith: 64)) == 0.5)
    }

    @Test func emptyMasksHaveNoOverlap() {
        let empty = MaskData(size: PixelSize(width: 0, height: 0), coverage: [])
        let blank = MaskData(size: PixelSize(width: 2, height: 2), filledWith: 0)
        #expect(empty.intersectionOverUnion(empty) == 0)
        #expect(blank.intersectionOverUnion(blank) == 0)
        #expect(blank.intersectionOverUnion(empty) == 0)
    }
}
