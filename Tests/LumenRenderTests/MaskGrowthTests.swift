import Foundation
import LumenCore
import Testing
@testable import LumenRender

/// A recolour's mask, held to the photo's edges, stopped short of a teal fender's rim and its shaded underside; they
/// kept the old teal beside the new red. It now grows over neighbouring pixels of the thing's own colour.
struct MaskGrowthTests {
    private func colours(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [ColourMeasurement] {
        (0..<(width * height)).map { index in
            let (r, g, b) = pixel(index % width, index / width)
            return ColourMeasuring.lab(red: r, green: g, blue: b)
        }
    }

    private func mask(width: Int, height: Int, _ covered: (Int, Int) -> Bool) -> MaskData {
        MaskData(size: PixelSize(width: width, height: height),
                 coverage: (0..<(width * height)).map { covered($0 % width, $0 / width) ? 255 : 0 })
    }

    @Test func aColourfulThingTakesInItsRimAndShadeButNotItsNeighbour() {
        // A teal fender at x 10..<50 with a dark teal shadow at y 40..<50, a black bag right of x 50, grey ground.
        let photo = colours(width: 80, height: 60) { x, y in
            if x >= 50 && x < 70 && y < 50 { return (12, 12, 14) }
            if x >= 10 && x < 50 && y < 40 { return (40, 120, 125) }
            if x >= 10 && x < 50 && y < 50 { return (14, 52, 56) }
            return (128, 120, 112)
        }
        // SAM's mask stopped 3 px inside the rim and left the shade out.
        let found = mask(width: 80, height: 60) { x, y in x >= 13 && x < 47 && y >= 3 && y < 37 }
        let grown = MaskGrowth.alike(found, colours: photo, reach: 12)
        #expect(grown[11, 20] == 255 && grown[48, 20] == 255 && grown[30, 1] == 255, "the rim")
        #expect(grown[30, 45] == 255, "the shaded underside")
        #expect(grown[55, 20] == 0, "not the black bag")
        #expect(grown[5, 20] == 0 && grown[30, 55] == 0, "not the ground")
    }

    @Test func aGreyThingGrowsByLightnessAndOnlySoFar() {
        // A light grey shirt left of x 40, a black backpack beyond; a grey wall continuing far above.
        let photo = colours(width: 80, height: 60) { x, y in
            if y < 10 { return (178, 178, 178) }
            return x < 40 ? (180, 180, 180) : (20, 20, 20)
        }
        let found = mask(width: 80, height: 60) { x, y in x < 37 && y >= 20 }
        let grown = MaskGrowth.alike(found, colours: photo, reach: 4)
        #expect(grown[38, 30] == 255 && grown[42, 30] == 0, "up to the backpack, not into it")
        #expect(grown[10, 16] == 255 && grown[10, 15] == 0, "no more than 4 px out")
        #expect(MaskGrowth.alike(found, colours: photo, reach: 0) == found)
    }
}
