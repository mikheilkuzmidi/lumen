import Foundation
import LumenCore
import Testing
@testable import LumenMeta

struct SAMPlacementTests {
    @Test func aSmallDiagonalRasterHasSmoothCoverageInsideItsBox() throws {
        let image = EncodedImage(data: Data(), format: .png, size: PixelSize(width: 24, height: 20))
        // A hand-built one-bit raster with four rows: 1000, 1100, 1110, 1111.
        let text = "<0f>1<|box;x1=4;y1=2;x2=19;y2=17;w=24;h=20|><|mask;x=0;y=0;data=4,4,!!!!!'Ob'7zQc|>"
        let mask = try #require(SAMSegments.parse(text, request: SegmentRequest(image: image)).first?.mask)
        #expect(mask[4, 2] == 255)
        #expect(mask[19, 2] == 0)
        #expect(mask[19, 17] == 255)
        #expect(mask[8, 5] > 0 && mask[8, 5] < 255)
        #expect(mask[12, 9] > 0 && mask[12, 9] < 255)
        #expect(Set(mask.coverage).count > 8)
        for y in 0..<20 {
            for x in 0..<24 where !(4..<20).contains(x) || !(2..<18).contains(y) {
                #expect(mask[x, y] == 0)
            }
        }
    }

    @Test func aRasterAlreadyAtBoxSizeKeepsItsCoverage() throws {
        let image = EncodedImage(data: Data(), format: .png, size: PixelSize(width: 6, height: 6))
        let text = "<0f>1<|box;x1=1;y1=1;x2=4;y2=4;w=6;h=6|><|mask;x=0;y=0;data=4,4,!!!!!'Ob'7zQc|>"
        let mask = try #require(SAMSegments.parse(text, request: SegmentRequest(image: image)).first?.mask)
        for y in 0..<4 {
            for x in 0..<4 { #expect(mask[x + 1, y + 1] == (x <= y ? 255 : 0)) }
        }
    }

    @Test func aSingleRasterPixelFillsOnlyItsBox() throws {
        let image = EncodedImage(data: Data(), format: .png, size: PixelSize(width: 6, height: 4))
        let text = "<0f>1<|box;x1=2;y1=1;x2=4;y2=2;w=6;h=4|><|mask;x=0;y=0;data=1,1,!!!!!&O.lVP|>"
        let mask = try #require(SAMSegments.parse(text, request: SegmentRequest(image: image)).first?.mask)
        for y in 0..<4 {
            for x in 0..<6 { #expect(mask[x, y] == ((2..<5).contains(x) && (1..<3).contains(y) ? 255 : 0)) }
        }
    }
}
