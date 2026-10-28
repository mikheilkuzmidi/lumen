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

    @Test func aTwoColourJacketGrowsOverBothItsColours() {
        // A jacket grey above (y < 20) and red below (y 20..<36) on white snow; SAM's mask has the grey part and only
        // the top of the red, as on the skier.
        let photo = colours(width: 60, height: 50) { x, y in
            guard (10..<50).contains(x), y < 36 else { return (245, 246, 250) }
            return y < 20 ? (95, 98, 102) : (210, 40, 35)
        }
        let found = mask(width: 60, height: 50) { x, y in (12..<48).contains(x) && y < 24 }
        let grown = MaskGrowth.alike(found, colours: photo, reach: 15)
        #expect(grown[30, 33] == 255, "the red lower part")
        #expect(grown[11, 10] == 255 && grown[48, 30] == 255, "both colours' edges")
        #expect(grown[30, 45] == 0 && grown[5, 10] == 0, "not the snow")
        #expect(MaskGrowth.mainColours([ColourMeasurement(lightness: 50, a: 0, b: 0)]).count == 1)
    }

    @Test func theEdgeWhereTheOldColourTintsThePixelsIsTakenIn() {
        // A red coat on snow, its edge blending over three pixels: pink, paler pink, almost white.
        let photo = colours(width: 60, height: 40) { x, _ in
            switch x {
            case ..<30: return (200, 30, 40)
            case 30: return (225, 140, 145)
            case 31: return (238, 200, 202)
            case 32: return (243, 232, 233)
            default: return (246, 246, 248)
            }
        }
        let found = mask(width: 60, height: 40) { x, _ in x < 30 }
        let withoutRing = MaskGrowth.alike(found, colours: photo, reach: 4)
        let withRing = MaskGrowth.alike(found, colours: photo, reach: 4, fringe: 3)
        #expect(withoutRing[31, 20] == 0, "too pale to pass for the coat")
        #expect(withRing[30, 20] == 255 && withRing[31, 20] == 255, "the tinted edge is taken in")
        #expect(withRing[34, 20] == 0, "the snow is not")
        // A soft mask edge over the coat's own last pixels: half covered, half the old red would show through.
        var soft = found
        for y in 0..<40 { soft.coverage[y * 60 + 29] = 140; soft.coverage[y * 60 + 30] = 60 }
        let firmed = MaskGrowth.alike(soft, colours: photo, reach: 4, fringe: 3)
        #expect(firmed[29, 20] == 255 && firmed[30, 20] == 255, "the coat's edge is covered fully")
        #expect(firmed[34, 20] == 0)
    }

    @Test func aColourfulThingReachesFurtherThanAGreyOne() {
        // A red coat with a strap sticking out 10 px past SAM's mask, over dark hair; and a grey shirt beside a grey wall.
        let photo = colours(width: 80, height: 40) { x, y in
            if x < 30 { return (200, 30, 40) }
            if (30..<42).contains(x), (18..<22).contains(y) { return (190, 28, 36) }
            if x >= 60 { return (150, 150, 150) }
            return (60, 40, 30)
        }
        let coat = mask(width: 80, height: 40) { x, _ in x < 30 }
        #expect(MaskGrowth.alike(coat, colours: photo, reach: 4)[40, 20] == 0, "the strap's tip is past a short reach")
        let far = MaskGrowth.alike(coat, colours: photo, reach: 4, colourfulReach: 12)
        #expect(far[40, 20] == 255 && far[41, 19] == 255, "but within a colourful one")
        #expect(far[45, 20] == 0 && far[35, 10] == 0, "not into the hair")
        let shirt = mask(width: 80, height: 40) { x, _ in x >= 62 }
        let wallBeside = colours(width: 80, height: 40) { x, _ in x >= 50 ? (150, 150, 150) : (60, 40, 30) }
        #expect(MaskGrowth.alike(shirt, colours: wallBeside, reach: 4, colourfulReach: 12)[55, 20] == 0, "grey grows only a little")
    }

    @Test func aGreyShirtsSoftEdgeIsNotFirmedOverAGreyHand() {
        // A light grey shirt and, beside it, a grey hand of nearly the same lightness, half covered by a soft mask edge.
        let photo = colours(width: 60, height: 20) { x, _ in x < 30 ? (180, 180, 180) : (170, 170, 170) }
        var soft = mask(width: 60, height: 20) { x, _ in x < 30 }
        for y in 0..<20 { for x in 30..<36 { soft.coverage[y * 60 + x] = 100 } }
        let result = MaskGrowth.alike(soft, colours: photo, reach: 1, colourfulReach: 8, fringe: 3)
        #expect(result[33, 10] == 100, "the hand keeps its soft coverage: \(result[33, 10])")
    }
}
