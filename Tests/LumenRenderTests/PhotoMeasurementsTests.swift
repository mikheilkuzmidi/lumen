import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import Testing
@testable import LumenRender

struct PhotoMeasurementsTests {
    /// A rolled camera leans the upright things in a photo with its horizon; verticals converging in a shot taken
    /// upward lean both ways and cancel.
    @Test func uprightLinesLeanWithARolledCameraAndCancelWhenTheyConverge() throws {
        func photo(_ draw: (CGContext) -> Void) -> CIImage {
            let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.8, green: 0.85, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            draw(context)
            return CIImage(cgImage: context.makeImage()!)
        }
        func poles(_ context: CGContext) {
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            for x in stride(from: -240, through: 240, by: 60) { context.fill(CGRect(x: x, y: -150, width: 8, height: 260)) }
        }
        for degrees in [3.0, -3.0] {
            let rolled = photo { context in
                context.translateBy(x: 300, y: 200)
                context.rotate(by: degrees * .pi / 180)
                poles(context)
            }
            let lean = try #require(try PhotoStatistics(photo: rolled, context: CIContext(), capturedAt: nil).facts.verticalLean)
            #expect(abs(lean - degrees) < 0.6, "rolled \(degrees)°, lean \(lean)")
        }
        // Poles converging toward the top, as in a shot taken upward: the left ones lean right, the right ones left.
        let converging = photo { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            for x in stride(from: 60.0, through: 540, by: 60) {
                let top = 300 + (x - 300) * 0.9, width = 8.0
                context.move(to: CGPoint(x: x, y: 60)); context.addLine(to: CGPoint(x: x + width, y: 60))
                context.addLine(to: CGPoint(x: top + width, y: 360)); context.addLine(to: CGPoint(x: top, y: 360))
                context.closePath(); context.fillPath()
            }
        }
        let lean = try #require(try PhotoStatistics(photo: converging, context: CIContext(), capturedAt: nil).facts.verticalLean)
        #expect(abs(lean) < 0.6, "converging verticals cancel: \(lean)")
        // A rolled horizon's long level line tilts with it.
        for degrees in [3.0, -3.0] {
            let horizon = photo { context in
                context.translateBy(x: 300, y: 200)
                context.rotate(by: degrees * .pi / 180)
                context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.5, alpha: 1)); context.fill(CGRect(x: -500, y: -500, width: 1000, height: 500))
            }
            let level = try #require(try PhotoStatistics(photo: horizon, context: CIContext(), capturedAt: nil).facts.levelTilt)
            #expect(abs(level - degrees) < 0.6, "horizon rolled \(degrees)°, level lines \(level)")
        }
        // An empty sky has no upright things to measure.
        #expect(try PhotoStatistics(photo: photo { _ in }, context: CIContext(), capturedAt: nil).facts.verticalLean == nil)
    }

    @Test func measuresBlackAndClippedPhotosWithoutARenderer() throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let black = try statistics(folder.photo(name: "black.png") { _, _ in (0, 0, 0) }).facts
        #expect(black.sharpness == 0 && black.exposure == 0)
        #expect(black.clippedShadows == 1 && black.clippedHighlights == 0)
        let clipped = try statistics(folder.photo(name: "clipped.png") { x, _ in
            x < 64 ? (3, 3, 3) : (252, 252, 252)
        }).facts
        #expect(clipped.clippedShadows == 0.5 && clipped.clippedHighlights == 0.5)
        #expect(abs(clipped.exposure - 0.5) < 0.000001)
        let bounded = try statistics(folder.photo(name: "bounded.png") { x, _ in
            x < 64 ? (6, 6, 6) : (249, 249, 249)
        }).facts
        #expect(bounded.clippedShadows == 0 && bounded.clippedHighlights == 0)
    }

    @Test func laplacianDistinguishesSharpAndBlurredCheckerboards() throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let width = 512, height = 384
        let sharp = try folder.photo(name: "sharp.png", width: width, height: height) { x, y in
            let value: UInt8 = (x / 8 + y / 8) % 2 == 0 ? 20 : 235
            return (value, value, value)
        }
        let pixels = try LibraryImages.pixels(Data(contentsOf: sharp)).bytes
        let weights = (-9...9).map { exp(-Double($0 * $0) / 18) }
        let total = weights.reduce(0, +)
        var across = [Double](repeating: 0, count: width * height)
        var blurred = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                for offset in -9...9 {
                    let source = y * width + min(width - 1, max(0, x + offset))
                    across[y * width + x] += Double(pixels[source * 4]) * weights[offset + 9] / total
                }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var value = 0.0
                for offset in -9...9 {
                    let source = min(height - 1, max(0, y + offset)) * width + x
                    value += across[source] * weights[offset + 9] / total
                }
                blurred[y * width + x] = UInt8(value.rounded())
            }
        }
        let blur = try folder.photo(name: "blur.png", width: width, height: height) { x, y in
            let value = blurred[y * width + x]
            return (value, value, value)
        }
        let sharpFacts = try statistics(sharp).facts
        let blurredFacts = try statistics(blur).facts
        #expect(sharpFacts.sharpness > blurredFacts.sharpness + 0.3)
        #expect((0...1).contains(sharpFacts.sharpness) && (0...1).contains(blurredFacts.sharpness))
        #expect(abs(sharpFacts.exposure - 0.5) < 0.01)
        let fine = try folder.photo(name: "fine.png", width: 512, height: 384) { x, y in
            let value: UInt8 = (x + y) % 2 == 0 ? 0 : 255
            return (value, value, value)
        }
        #expect(abs(try statistics(fine).facts.sharpness - 16 / 16.01) < 0.000001)
    }

    @Test func autoMovesOnlyLightnessOutOfRangeAndDampsGreyWorldColour() throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        // Halfway toward 0.35...0.6, at most 0.7 stop either way.
        for (name, level, exposure) in [("dark.png", UInt8(40), 0.7), ("bright.png", 240, -0.7)] {
            let photo = try folder.photo(name: name) { _, _ in (level, level, level) }
            #expect(try statistics(photo).autoValues[.exposure] == exposure)
        }
        let balanced = try folder.photo(name: "balanced.png") { _, _ in (115, 115, 115) }
        // A neutral grey in range needs nothing, and black and white gets no vibrance.
        #expect(try statistics(balanced).autoValues == [:])
        let cast = try folder.photo(name: "cast.png") { _, _ in (150, 100, 90) }
        let values = try statistics(cast).autoValues
        let grey: Double = 340.0 / 3
        let temperature: Double = max(-5, -60.0 / grey * 9), tint: Double = 20.0 / grey * 15
        #expect(abs((values[.temperature] ?? 0) - temperature) < 0.001)
        #expect(abs((values[.tint] ?? 0) - tint) < 0.001)
        #expect(values[.vibrance] == nil)
        let narrow = try folder.photo(name: "narrow.png", width: 512, height: 384) { x, _ in
            let value = UInt8(25 + Double(x) / 511 * 180)
            return (value, value, value)
        }
        let levels = try statistics(narrow).autoValues
        #expect((levels[.blacks] ?? 0) < 0 && (levels[.whites] ?? 0) > 0)
        #expect(abs(levels[.blacks] ?? 0) <= 20 && abs(levels[.whites] ?? 0) <= 20)
    }

    @Test func readsEXIFDatesWithAndWithoutAnOffset() throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        for offset in ["-04:00", ""] {
            var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:24 12:34:56"]
            if !offset.isEmpty { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
            let url = try folder.photo(name: "date.jpg", exif: exif)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let expected = offset.isEmpty ? "2026-10-24T12:34:56Z" : "2026-10-24T16:34:56Z"
            #expect(PhotoStatistics.capturedAt(in: properties) == ISO8601DateFormatter().date(from: expected))
        }
        #expect(PhotoStatistics.capturedAt(in: nil) == nil)
        #expect(PhotoStatistics.capturedAt(in: [kCGImagePropertyExifDictionary:
                    [kCGImagePropertyExifDateTimeOriginal: "not a date"]]) == nil)
    }

    @Test(arguments: [-10.0, 10, 90])
    func straighteningChangesTheCanvasBeforeRendering(degrees: Double) async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let url = try folder.photo(name: "one.png", width: 400, height: 300)
        let document = try PhotoDocument(contentsOf: url)
        try await document.straighten(degrees: degrees)
        let expected = degrees == 90 ? PixelSize(width: 300, height: 225) : PixelSize(width: 328, height: 246)
        #expect(await document.size() == expected)
        #expect(await document.straighteningAngle == degrees)
        try await document.straighten(degrees: degrees)
        #expect(await document.size() == expected, "Setting an angle does not compound the crop.")
        await #expect(throws: LumenError.self) { try await document.straighten(degrees: .infinity) }
        #expect(await document.straighteningAngle == degrees)
        try await document.straighten(degrees: 0)
        #expect(await document.size() == PixelSize(width: 400, height: 300))
    }

    private func statistics(_ url: URL) throws -> PhotoStatistics {
        let sample = try LibraryImages.pixels(Data(contentsOf: url))
        return PhotoStatistics(pixels: sample.bytes, width: sample.size.width, height: sample.size.height,
                               photoSize: sample.size)
    }
}
