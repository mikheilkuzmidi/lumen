import Testing
@testable import LumenCore

@Suite("Mask operations")
struct MaskOpsTests {
    @Test func boundsIncludeWholeCoveredPixels() {
        let mask = MaskData(size: PixelSize(width: 4, height: 2), coverage: [0, 1, 0, 0, 0, 0, 255, 0])
        #expect(mask.boundingBox == NormalizedRect(x: 0.25, y: 0, width: 0.5, height: 1))
        #expect(MaskData(size: mask.size, filledWith: 0).boundingBox == nil)
        #expect(MaskData(size: PixelSize(width: 0, height: 0), coverage: []).boundingBox == nil)
    }

    @Test func unionAndInvertPreserveSoftCoverage() {
        let size = PixelSize(width: 2, height: 2)
        let mask = MaskData(size: size, coverage: [0, 64, 128, 255])
        #expect(mask.union(MaskData(size: size, coverage: [20, 10, 200, 0])).coverage == [20, 64, 200, 255])
        #expect(mask.inverted().coverage == [255, 191, 127, 0])
        #expect(mask.union(MaskData(size: PixelSize(width: 1, height: 1), filledWith: 100)).coverage == [100, 100, 128, 255])
        #expect(abs(mask.area - 447.0 / 1020.0) < 0.000001)
        #expect(MaskData(size: PixelSize(width: 0, height: 0), coverage: []).area == 0)
    }

    @Test func cropKeepsIntersectingPixelsAndClipsAtThePhoto() {
        let mask = MaskData(size: PixelSize(width: 4, height: 2), coverage: [0, 1, 2, 3, 4, 5, 6, 7])
        let crop = mask.cropped(to: NormalizedRect(x: 0.25, y: 0, width: 0.5, height: 0.5))
        #expect(crop.size == PixelSize(width: 2, height: 1))
        #expect(crop.coverage == [1, 2])
        #expect(mask.cropped(to: NormalizedRect(x: -0.5, y: 0.5, width: 1, height: 1)).coverage == [4, 5])
        #expect(mask.cropped(to: NormalizedRect(x: 2, y: 0, width: 1, height: 1)).coverage.isEmpty)
        #expect(mask.cropped(to: NormalizedRect(x: .nan, y: 0, width: 1, height: 1)).coverage.isEmpty)
        #expect(mask.cropped(to: .whole) == mask)
        let decimalEdges = MaskData(size: PixelSize(width: 10, height: 10), filledWith: 255)
            .cropped(to: NormalizedRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        #expect(decimalEdges.size == PixelSize(width: 4, height: 4))
    }

    @Test func resizeInterpolatesBothAxesAtPixelCenters() {
        let mask = MaskData(size: PixelSize(width: 2, height: 2), coverage: [0, 100, 200, 255])
        #expect(mask.resized(to: PixelSize(width: 1, height: 1)).coverage == [139])
        #expect(mask.resized(to: PixelSize(width: 3, height: 3)).coverage == [0, 50, 100, 100, 139, 178, 200, 228, 255])
        #expect(mask.resized(to: mask.size) == mask)
        #expect(mask.resized(to: PixelSize(width: 0, height: 0)).coverage.isEmpty)
        #expect(MaskData(size: PixelSize(width: 0, height: 0), coverage: []).resized(to: mask.size).coverage == [0, 0, 0, 0])
    }

    @Test func growthUsesACircularRadiusAndKeepsSoftEdges() {
        let mask = MaskData(size: PixelSize(width: 3, height: 3), coverage: [0, 0, 0, 0, 128, 0, 0, 0, 0])
        #expect(mask.grown(by: 1).coverage == [0, 128, 0, 128, 128, 128, 0, 128, 0])
        #expect(mask.grown(by: 2).coverage == [UInt8](repeating: 128, count: 9))
        #expect(mask.grown(by: 0) == mask)
        #expect(mask.grown(by: -1) == mask)
        #expect(mask.grown(by: .max).coverage == [UInt8](repeating: 128, count: 9))
    }

    @Test(arguments: [1, 2, 3, 8]) func growthMatchesCoverageWithinTheRadius(radius: Int) {
        let size = PixelSize(width: 7, height: 5)
        let mask = MaskData(size: size, coverage: (0..<35).map { UInt8(($0 * 37) % 256) })
        let grown = mask.grown(by: radius)
        for y in 0..<size.height {
            for x in 0..<size.width {
                var expected: UInt8 = 0
                for otherY in 0..<size.height {
                    for otherX in 0..<size.width {
                        let distance = (otherX - x) * (otherX - x) + (otherY - y) * (otherY - y)
                        if distance <= radius * radius { expected = max(expected, mask[otherX, otherY]) }
                    }
                }
                #expect(grown[x, y] == expected)
            }
        }
    }

    @Test func blurringSoftensTheEdgeAndKeepsTheMiddle() {
        var coverage = [UInt8](repeating: 0, count: 60 * 40)
        for y in 10..<30 { for x in 20..<40 { coverage[y * 60 + x] = 255 } }
        let square = MaskData(size: PixelSize(width: 60, height: 40), coverage: coverage)
        let soft = square.blurred(by: 2)
        #expect(soft[30, 20] == 255, "the middle stays covered")
        #expect(soft[0, 0] == 0 && soft[59, 39] == 0, "far outside stays clear")
        #expect((100...155).contains(soft[20, 20]), "the edge is about half covered: \(soft[20, 20])")
        #expect(soft[17, 20] > 0 && soft[17, 20] < soft[19, 20] && soft[22, 20] < 255)
        #expect(square.blurred(by: 0.2) == square)
        // A mask touching the border is not dimmed there.
        #expect(MaskData(size: PixelSize(width: 8, height: 8), filledWith: 255).blurred(by: 3)[0, 0] == 255)
    }

    @Test func aGradientFallsFromFullToNoneAndFadesWhatItMultiplies() {
        let size = PixelSize(width: 100, height: 50)
        let light = MaskData.gradient(size: size, from: NormalizedPoint(x: 1, y: 0.5), to: NormalizedPoint(x: 0.2, y: 0.5))
        #expect(light[99, 25] > 250 && light[0, 25] == 0 && light[19, 25] == 0)
        #expect((120...135).contains(light[60, 25]), "half way, half the light: \(light[60, 25])")
        #expect(light[60, 0] == light[60, 49], "it runs across, not down")
        #expect(light[80, 25] > light[60, 25] && light[60, 25] > light[40, 25])
        let sky = MaskData(size: size, coverage: (0..<5000).map { $0 / 100 < 20 ? 255 : 0 })
        let near = sky.multiplied(by: light)
        #expect(near[99, 5] > 250 && near[99, 40] == 0 && near[10, 5] == 0)
        #expect(MaskData.gradient(size: size, from: NormalizedPoint(x: 0.5, y: 0.5), to: NormalizedPoint(x: 0.5, y: 0.5)).boundingBox == nil)
    }

    @Test func aSubjectsShadowLiesAlongTheGroundFromItsBase() {
        // A post at x 40..<44 standing on y 59; the sun on the left lays its shadow out to the right.
        let post = MaskData(size: PixelSize(width: 100, height: 80), coverage: (0..<8000).map {
            (40..<44).contains($0 % 100) && (20..<60).contains($0 / 100) ? 255 : 0
        })
        let shadow = post.castShadow(tip: NormalizedPoint(x: 0.95, y: 0.76))
        #expect(shadow[50, 60] > 150, "dark beside the base: \(shadow[50, 60])")
        #expect(shadow[90, 61] > 20 && shadow[90, 61] < shadow[50, 60], "fading toward the tip: \(shadow[90, 61])")
        #expect(shadow[42, 40] == 0, "never over the post itself")
        #expect(shadow[20, 60] < 10 && shadow[60, 30] < 10, "not on the lit side or in the air")
        // Laid along the ground, it still has some thickness across.
        #expect(shadow[70, 59] > 60 && shadow[70, 61] > 30)
        #expect(MaskData(size: post.size, filledWith: 0).castShadow(tip: NormalizedPoint(x: 1, y: 1)).boundingBox == nil)
    }

    @Test func eachFigureInAGroupCastsFromItsOwnFeet() {
        // A tall figure standing on y 59 and a short one standing higher up, on y 39.
        let group = MaskData(size: PixelSize(width: 100, height: 80), coverage: (0..<8000).map {
            let x = $0 % 100, y = $0 / 100
            return ((20..<24).contains(x) && (20..<60).contains(y)) || ((60..<64).contains(x) && (20..<40).contains(y)) ? 255 : 0
        })
        let shadow = group.castShadow(tip: NormalizedPoint(x: 0.6, y: 0.76))
        #expect(shadow[30, 60] > 120, "the tall one's shadow starts at its feet")
        #expect(max(shadow[68, 39], shadow[68, 40]) > 60, "the short one's starts at its own feet, higher up")
        #expect(shadow[68, 60] < 30, "not at the tall one's ground level")
        #expect(group.components().count == 2)
    }
}
