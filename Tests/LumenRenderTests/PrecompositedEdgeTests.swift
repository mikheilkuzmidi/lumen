import CoreGraphics
import CoreImage
import Foundation
import LumenCore
import Testing
@testable import LumenRender

/// The generated crop is already a finished, antialiased photo. Applying its
/// physical edge alpha a second time mixes the old garment back into it.
struct PrecompositedEdgeTests {
    private struct Scene {
        var old: (UInt8, UInt8, UInt8)
        var new: (UInt8, UInt8, UInt8)
        var background: (UInt8, UInt8, UInt8)
    }

    private func alpha(_ x: Int) -> Double {
        switch x {
        case ..<76: 1
        case 76: 0.9
        case 77: 0.75
        case 78: 0.5
        case 79: 0.25
        case 80: 0.1
        default: 0
        }
    }

    private func mixed(_ foreground: (UInt8, UInt8, UInt8), _ background: (UInt8, UInt8, UInt8), alpha: Double) -> (UInt8, UInt8, UInt8) {
        func channel(_ f: UInt8, _ b: UInt8) -> UInt8 {
            func linear(_ byte: UInt8) -> Double {
                let x = Double(byte) / 255
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            let value = linear(f) * alpha + linear(b) * (1 - alpha)
            let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
            return UInt8((min(1, max(0, encoded)) * 255).rounded())
        }
        return (channel(foreground.0, background.0), channel(foreground.1, background.1), channel(foreground.2, background.2))
    }

    @Test(arguments: [0, 1, 2, 3])
    func finishedGarmentEdgeIsNotMattedTwice(sceneIndex: Int) async throws {
        let scenes = [
            Scene(old: (18, 25, 32), new: (240, 210, 35), background: (235, 240, 245)),
            Scene(old: (155, 155, 155), new: (225, 35, 50), background: (45, 100, 55)),
            Scene(old: (205, 35, 45), new: (25, 55, 100), background: (240, 240, 240)),
            Scene(old: (240, 240, 240), new: (18, 20, 24), background: (45, 100, 55)),
        ]
        let scene = scenes[sceneIndex]
        let folder = try LibraryFolder(); defer { folder.remove() }
        func photo(_ colour: (UInt8, UInt8, UInt8), x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            if (25..<28).contains(x), (25..<70).contains(y) { return (8, 10, 12) } // original black cord
            if (48..<58).contains(x), (10..<22).contains(y) { return (181, 137, 115) } // protected face/skin
            let shaded = (60..<65).contains(y) ? (UInt8(Double(colour.0) * 0.65), UInt8(Double(colour.1) * 0.65), UInt8(Double(colour.2) * 0.65)) : colour
            return mixed(shaded, scene.background, alpha: alpha(x))
        }
        let originalURL = try folder.photo(name: "original.png") { x, y in photo(scene.old, x: x, y: y) }
        let generatedURL = try folder.photo(name: "generated.png") { x, y in photo(scene.new, x: x, y: y) }
        let document = try PhotoDocument(contentsOf: originalURL)
        let mask = MaskData(size: PixelSize(width: 128, height: 96), coverage: (0..<(128 * 96)).map { index in
            UInt8((alpha(index % 128) * 255).rounded())
        })
        let assets = AssetStore()
        let generatedData = try Data(contentsOf: generatedURL)
        let prepared = try #require(await document.recolourEdges(EncodedImage(data: generatedData, format: .png, size: mask.size),
                                                                over: EncodedImage(data: Data(contentsOf: originalURL), format: .png, size: mask.size),
                                                                within: mask))
        let maskID = await assets.put(.mask(prepared.mask))
        let patchID = await assets.put(.image(prepared.image))
        let layer = Layer(label: "Garment recolour", content: .patch(image: patchID, mask: maskID, rect: .whole), precompositedEdges: true)
        try await document.apply(layer, assets: assets)
        let output = folder.output.appendingPathComponent("edge.png")
        try FileManager.default.createDirectory(at: folder.output, withIntermediateDirectories: true)
        try await document.export(to: output, format: .png)
        // Existing global patch colour matching is independent of this
        // regression. The finished patch AFTER that correction is the truth
        // being composited; a second matte must not add the old garment to it.
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                          .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let sourceImage = try #require(CIImage(contentsOf: originalURL))
        let generatedImage = try #require(CIImage(data: generatedData))
        let provider = try #require(CGDataProvider(data: Data(prepared.mask.coverage) as CFData))
        let maskCG = try #require(CGImage(width: 128, height: 96, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 128,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                                         decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let maskImage = CIImage(cgImage: maskCG, options: [.colorSpace: NSNull()])
        let corrected = PhotoCompositor.colorMatched(generatedImage, to: sourceImage, mask: maskImage, context: context)
        let correctedData = try #require(context.pngRepresentation(of: corrected, format: .RGBA8,
                                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let expected = try LibraryImages.pixels(correctedData)
        let originalPixels = try LibraryImages.pixels(Data(contentsOf: originalURL))
        let actual = try LibraryImages.pixels(Data(contentsOf: output))
        func difference(x: Int, y: Int) -> Int {
            let at = (y * 128 + x) * 4
            return (0..<3).map { abs(Int(expected.bytes[at + $0]) - Int(actual.bytes[at + $0])) }.max()!
        }
        let edgeErrors = [48, 62].flatMap { y in (76...80).map { difference(x: $0, y: y) } }
        #expect(edgeErrors.max()! <= 5, "already-composited edge must match its known truth: \(edgeErrors)")
        let outside = (48 * 128 + 100) * 4
        #expect((0..<3).allSatisfy { abs(Int(actual.bytes[outside + $0]) - Int(originalPixels.bytes[outside + $0])) <= 2 },
                "background outside the object is unchanged")
        #expect(difference(x: 26, y: 40) <= 3, "the original black cord stays black")
        #expect(difference(x: 52, y: 16) <= 3, "skin is not recoloured")
        #expect(difference(x: 50, y: 62) <= 4, "the generated natural shadow stays intact")
        await document.setOpacity(0.5, for: layer.id)
        let halfOutput = folder.output.appendingPathComponent("half-strength.png")
        try await document.export(to: halfOutput, format: .png)
        let half = try LibraryImages.pixels(Data(contentsOf: halfOutput))
        for x in 76...80 {
            let at = (48 * 128 + x) * 4
            let wanted = mixed((expected.bytes[at], expected.bytes[at + 1], expected.bytes[at + 2]),
                               (originalPixels.bytes[at], originalPixels.bytes[at + 1], originalPixels.bytes[at + 2]), alpha: 0.5)
            #expect(abs(Int(half.bytes[at]) - Int(wanted.0)) <= 5
                    && abs(Int(half.bytes[at + 1]) - Int(wanted.1)) <= 5
                    && abs(Int(half.bytes[at + 2]) - Int(wanted.2)) <= 5,
                    "intentional layer opacity is still applied once at the physical edge")
        }
    }

    @Test func anIntentionalSoftMaskIsNotFirmedAsASubjectMatte() {
        let size = PixelSize(width: 128, height: 32)
        let mask = MaskData(size: size, coverage: (0..<(size.width * size.height)).map { UInt8((alpha($0 % size.width) * 255).rounded()) },
                            followsPhoto: false)
        let colours = (0..<(size.width * size.height)).map { index in
            let (r, g, b) = mixed((20, 20, 20), (240, 240, 240), alpha: alpha(index % size.width))
            return ColourMeasuring.lab(red: r, green: g, blue: b)
        }
        let kept = MaskGrowth.alike(mask, colours: colours, reach: 1, fringe: 3)
        #expect(kept.coverage == mask.coverage, "drawn falloff is intentional coverage, not a second object matte")
    }

    @Test func nearbyDarkBackgroundIsNotPromotedToGarmentSupport() throws {
        let width = 128, height = 96
        let size = PixelSize(width: width, height: height)
        let folder = try LibraryFolder(); defer { folder.remove() }
        func edge(_ x: Int) -> Double { x < 64 ? 1 : x == 64 ? 0.75 : x == 65 ? 0.25 : 0 }
        let original = try folder.photo(name: "source.png") { x, _ in
            mixed((32, 38, 48), (34, 46, 25), alpha: edge(x))
        }
        let generated = try folder.photo(name: "generated.png") { x, _ in
            x > 65 ? (210, 180, 40) : mixed((240, 210, 35), (34, 46, 25), alpha: edge(x))
        }
        let mask = MaskData(size: size, coverage: (0..<(width * height)).map { UInt8((edge($0 % width) * 255).rounded()) })
        let generatedData = try Data(contentsOf: generated)
        let originalData = try Data(contentsOf: original)
        let preparation = try RecolourEdges.prepare(EncodedImage(data: generatedData, format: .png, size: size),
                                                    over: EncodedImage(data: originalData, format: .png, size: size), within: mask)
        let prepared = try #require(preparation)
        #expect(prepared.image.data == generatedData, "finished model pixels are not recoloured or sharpened again")
        #expect(prepared.mask[64, 48] == 255 && prepared.mask[65, 48] == 255, "actual antialiased garment edge receives the finished crop once")
        #expect(prepared.mask[66, 48] <= 2 && prepared.mask[67, 48] <= 2,
                "source-green background stays background even when the generator changed it: \(prepared.mask[66, 48]), \(prepared.mask[67, 48])")
    }
}
