import CoreGraphics
import CoreImage
import Foundation
import LumenCore
import Testing
@testable import LumenRender

struct EnlargedPrecompositedEdgeTests {
    @Test func preparedPixelsStopAtBlackWithoutClippingHDRorLegacyFloatValues() {
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let signed = CIImage(color: .white).cropped(to: bounds).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -0.25, y: 1.5, z: 0.5, w: 1),
        ])
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                          .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        func pixels(prepared: Bool) -> [Float] {
            let image = EditSupport.matchedPatch(signed, to: signed, within: CIImage(color: .white).cropped(to: bounds),
                                                enlargement: 1, restoresDetail: false, precompositedEdges: prepared, context: context)
            var values = [Float](repeating: 0, count: 4)
            values.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: bounds,
                               format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            }
            return values
        }
        let finished = pixels(prepared: true), legacy = pixels(prepared: false)
        #expect(abs(finished[0]) < 0.0001, "finished photo pixels stop at physical black before layer opacity")
        #expect(abs(finished[1] - 1.5) < 0.0001, "HDR radiance above white stays above white")
        #expect(abs(finished[2] - 0.5) < 0.0001 && abs(finished[3] - 1) < 0.0001)
        #expect(abs(legacy[0] + 0.25) < 0.0001 && abs(legacy[1] - 1.5) < 0.0001,
                "ordinary signed floating-point rendering retains its semantics")
    }

    @Test(arguments: [false, true])
    func anEnlargedFinishedEdgeDoesNotBorrowTheOldSilhouette(lightToDark: Bool) async throws {
        let folder = try LibraryFolder(); defer { folder.remove() }
        let old = lightToDark ? (240, 240, 240) : (18, 25, 32)
        let new = lightToDark ? (18, 20, 24) : (240, 210, 35)
        let background = lightToDark ? (45, 100, 55) : (235, 240, 245)
        func alpha(_ x: Int) -> Double {
            switch x { case ..<76: 1; case 76: 0.9; case 77: 0.75; case 78: 0.5; case 79: 0.25; case 80: 0.1; default: 0 }
        }
        func photo(_ colour: (Int, Int, Int), x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            if (25..<28).contains(x), (25..<70).contains(y) { return (8, 10, 12) }
            if (48..<58).contains(x), (10..<22).contains(y) { return (181, 137, 115) }
            func mix(_ foreground: Int, _ back: Int) -> UInt8 {
                func linear(_ value: Int) -> Double {
                    let c = Double(value) / 255
                    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                }
                let shade = (60..<65).contains(y) ? 0.65 : 1.0
                let value = alpha(x) * linear(Int(Double(foreground) * shade)) + (1 - alpha(x)) * linear(back)
                let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
                return UInt8((min(1, max(0, encoded)) * 255).rounded())
            }
            return (mix(colour.0, background.0), mix(colour.1, background.1), mix(colour.2, background.2))
        }
        let original = try folder.photo(name: "request.png") { photo(old, x: $0, y: $1) }
        let fullOriginal = try folder.photo(name: "native.png", width: 256, height: 192) { x, y in
            photo(old, x: x / 2, y: y / 2)
        }
        let generated = try folder.photo(name: "generated.png") { photo(new, x: $0, y: $1) }
        let size = PixelSize(width: 128, height: 96)
        let data = try Data(contentsOf: generated)
        let mask = MaskData(size: size, coverage: (0..<(128 * 96)).map { UInt8((alpha($0 % 128) * 255).rounded()) })
        let preparation = try RecolourEdges.prepare(EncodedImage(data: data, format: .png, size: size),
                                                    over: EncodedImage(data: Data(contentsOf: original), format: .png, size: size), within: mask)
        let prepared = try #require(preparation)
        let document = try PhotoDocument(contentsOf: fullOriginal)
        let assets = AssetStore()
        let maskID = await assets.put(.mask(prepared.mask)), imageID = await assets.put(.image(prepared.image))
        try await document.apply(Layer(label: "Enlarged colour", content: .patch(image: imageID, mask: maskID, rect: .whole),
                                       precompositedEdges: true), assets: assets)
        let output = folder.root.appendingPathComponent("output.png")
        try await document.export(to: output, format: .png)
        let actual = try LibraryImages.pixels(Data(contentsOf: output))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                          .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let source = try #require(CIImage(contentsOf: fullOriginal))
        let patch = PhotoCompositor.resized(try #require(CIImage(data: data)), to: source.extent)
        let provider = try #require(CGDataProvider(data: Data(prepared.mask.coverage) as CFData))
        let maskImage = try #require(CGImage(width: 128, height: 96, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 128,
                                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                                            decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let coverage = PhotoCompositor.scaledMask(CIImage(cgImage: maskImage, options: [.colorSpace: NSNull()]), to: source.extent,
                                                precomposited: true)
        let corrected = PhotoCompositor.colorMatched(patch, to: source, mask: coverage, context: context)
        let expectedData = try #require(context.pngRepresentation(of: corrected, format: .RGBA8,
                                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let expected = try LibraryImages.pixels(expectedData)
        let errors = [96, 124].flatMap { y in (152...161).map { x in
            let i = (y * 256 + x) * 4
            return (0..<3).map { abs(Int(actual.bytes[i + $0]) - Int(expected.bytes[i + $0])) }.max()!
        } }
        #expect(errors.max()! <= 5, "enlarging a prepared crop must not restore its old silhouette: \(errors)")
    }
}
