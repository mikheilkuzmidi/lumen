import AppKit
import LumenCore
import SwiftUI
import Testing
@testable import LumenStudio

struct StudioCanvasTests {
    @Test func selectionFramesRevealSmoothlyAndSettle() {
        let start = StudioSelectionFrame(elapsed: 0, reduceMotion: false)
        let snapshot = StudioSelectionFrame(elapsed: 0.6, reduceMotion: false)
        let settled = StudioSelectionFrame(elapsed: 3, reduceMotion: false)
        #expect(start.drawn == 0 && start.tint == 0)
        #expect(snapshot.drawn == 1 && snapshot.tint > 0.1)
        #expect(snapshot.shimmer > -0.6 && snapshot.shimmer < 1.3)
        #expect(abs(settled.tint - 0.1) < 0.0001)
        let reduced = StudioSelectionFrame(elapsed: 0, reduceMotion: true)
        #expect(reduced.drawn == 1 && reduced.tint == 0.12)
    }

    /// A selection's tint washed over the whole photo in a window capture: its mask was a grey image read through
    /// luminanceToAlpha. The mask is now an alpha mask, so only what was found is tinted, however it is drawn.
    @MainActor @Test func onlyWhatWasFoundIsTinted() throws {
        let mask = MaskData(size: PixelSize(width: 40, height: 10), coverage: (0..<400).map { $0 % 40 < 20 ? 255 : 0 })
        let region = StudioRegion(name: "jacket", segment: Segment(label: "jacket", box: mask.boundingBox!, mask: mask), colorIndex: 0)
        let image = try #require(region.mask)
        let renderer = ImageRenderer(content: Color.red.mask { Image(nsImage: image).resizable() }.frame(width: 40, height: 10))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 40 * 10 * 4)
        let context = try #require(CGContext(data: &pixels, width: 40, height: 10, bitsPerComponent: 8, bytesPerRow: 160,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: 40, height: 10))
        #expect(pixels[(5 * 40 + 5) * 4 + 3] > 240, "the found half is tinted")
        #expect(pixels[(5 * 40 + 35) * 4 + 3] < 15, "the rest is not")
    }
}
