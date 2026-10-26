import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LumenCore
import Testing
@testable import LumenRender

struct MaskRefinementTests {
    /// A photo split by a diagonal edge, and a mask that follows it in coarse steps, as SAM's masks can.
    private struct Diagonal {
        let side = 120
        func edge(at y: Int) -> Double { 30 + Double(y) * 0.5 }
        var guide: [Float] {
            (0..<(side * side)).map { index in Double(index % side) + 0.5 < edge(at: index / side) ? 0.2 : 0.8 }
        }
        var steps: MaskData {
            let coverage = (0..<(side * side)).map { index -> UInt8 in
                let band = (index / side) / 8 * 8 + 4
                return Double(index % side) + 0.5 < edge(at: band) ? 255 : 0
            }
            return MaskData(size: PixelSize(width: side, height: side), coverage: coverage)
        }
        /// How far, on average, each row's half-coverage point lies from the photo's edge, in pixels.
        func error(_ mask: MaskData) -> Double {
            var total = 0.0
            for y in 0..<side {
                let row: [Double] = mask.coverage[(y * side)..<((y + 1) * side)].map { Double($0) / 255 }
                var crossing = 0.0
                for x in 1..<side where row[x - 1] >= 0.5 && row[x] < 0.5 {
                    let drop = max(0.001, row[x - 1] - row[x])
                    crossing = Double(x) - 0.5 + (row[x - 1] - 0.5) / drop
                    break
                }
                total += abs(crossing - edge(at: y))
            }
            return total / Double(side)
        }
    }

    @Test func blockyEdgesFollowThePhoto() {
        let photo = Diagonal()
        let refined = MaskRefinement.refined(photo.steps, guide: photo.guide, radius: 4)
        #expect(photo.error(refined) < photo.error(photo.steps) * 0.5,
                "staircase \(photo.error(photo.steps)), refined \(photo.error(refined))")
    }

    @Test func pixelsFarFromTheMaskStayUncovered() {
        let side = 64, radius = 3
        let coverage = (0..<(side * side)).map { index -> UInt8 in
            let x = index % side, y = index / side
            return (20..<30).contains(x) && (20..<30).contains(y) ? 255 : 0
        }
        let guide = (0..<(side * side)).map { index in Float((index * 7919) % 101) / 100 }
        let refined = MaskRefinement.refined(MaskData(size: PixelSize(width: side, height: side), coverage: coverage),
                                             guide: guide, radius: radius)
        for index in refined.coverage.indices {
            let x = index % side, y = index / side
            let distance = max(max(0, 20 - x, x - 29), max(0, 20 - y, y - 29))
            if distance > 2 * radius { #expect(refined.coverage[index] == 0, "at \(x), \(y)") }
        }
    }

    @Test func aFullMaskStaysFullUpToThePhotosBorder() {
        let side = 40
        let guide = (0..<(side * side)).map { index in Float(index % side) / Float(side) }
        let full = MaskData(size: PixelSize(width: side, height: side), filledWith: 255)
        #expect(MaskRefinement.refined(full, guide: guide, radius: 5) == full)
    }

    @Test func aChangeFadesOutAcrossASmoothGradientButStopsAtAnEdge() {
        let width = 200, height = 60
        // Left half: a smooth gradient with the mask ending abruptly in it. Right half: the mask ends on a hard edge.
        let guide = (0..<(width * height)).map { index -> Float in
            let x = index % width
            return x < 100 ? 0.3 + Float(x) * 0.002 : (x < 150 ? 0.2 : 0.8)
        }
        let coverage = (0..<(width * height)).map { index -> UInt8 in
            let x = index % width
            return (x < 50 || (x >= 100 && x < 150)) ? 255 : 0
        }
        let softened = MaskRefinement.softenedWhereFlat(MaskData(size: PixelSize(width: width, height: height), coverage: coverage),
                                                        guide: guide, radius: 12)
        let row = 30 * width
        #expect(softened.coverage[row + 46] < 230 && softened.coverage[row + 54] > 25, "the gradient gets a gradual transition")
        #expect(softened.coverage[row + 148] > 200 && softened.coverage[row + 152] < 55, "the hard edge stays sharp")
        #expect(softened.coverage[row + 20] == 255 && softened.coverage[row + 80] == 0, "far from the boundary nothing changes")
    }

    @Test func radiusGrowsWithTheMask() {
        #expect(MaskRefinement.radius(for: PixelSize(width: 100, height: 80)) == 3)
        #expect(MaskRefinement.radius(for: PixelSize(width: 1536, height: 1024)) == 10)
    }
}

@Suite(.enabled(if: MaskRefinementTests.renderingAvailable, "Core Image rendering is unavailable on this host."))
struct RefinedAdjustmentTests {
    /// A sky mask along the photo's top edge: the border keeps its full change and the ground stays untouched.
    @Test func adjustmentReachesThePhotosBorderAndNotTheGround() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sky.png")
        let width = 640, height = 480
        var bytes: [UInt8] = []
        for y in 0..<height {
            for _ in 0..<width { bytes += y < 240 ? [120, 160, 220, 255] : [80, 90, 60, 255] }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        // SAM's sky stops in blocks of 8 px, 4 px above or below the horizon at row 240.
        let coverage = (0..<(width * height)).map { index -> UInt8 in
            let x = index % width, y = index / width
            return y < (x / 8 % 2 == 0 ? 236 : 244) ? 255 : 0
        }
        let assets = AssetStore()
        let id = await assets.put(.mask(MaskData(size: PixelSize(width: width, height: height), coverage: coverage)))
        let document = try PhotoDocument(contentsOf: url)
        let before = try await rows(document, folder: folder)
        try await document.apply(Layer(label: "Sky", content: .adjustment(values: [.exposure: -1], mask: id)), assets: assets)
        let after = try await rows(document, folder: folder)
        let change = { (x: Int, y: Int) in abs(after[y * width + x] - before[y * width + x]) / max(0.001, before[y * width + x]) }
        #expect(change(0, 0) > 0.48 && change(width - 1, 0) > 0.48, "the top border is darkened fully")
        // Unrefined, these are 0 and 0.5: hard blocks along the horizon.
        #expect(change(4, 238) > 0.25, "sky that SAM left out above the horizon is darkened")
        #expect(change(12, 242) < 0.2, "ground that SAM took for sky is mostly left alone")
        #expect(abs(change(4, 238) - change(12, 238)) < 0.3, "neighbouring blocks no longer stand apart")
        let untouched = (280..<height).allSatisfy { y in (0..<width).allSatisfy { x in change(x, y) == 0 } }
        #expect(untouched, "the ground below the horizon's reach is unchanged")
    }

    private func rows(_ document: PhotoDocument, folder: URL) async throws -> [Float] {
        let url = folder.appendingPathComponent(UUID().uuidString + ".png")
        try await document.export(to: url, format: .png)
        let image = try #require(CIImage(contentsOf: url))
        // Core Image writes the top row first.
        var pixels = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CIContext().render(image, toBitmap: buffer.baseAddress!, rowBytes: Int(image.extent.width) * 16,
                               bounds: image.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return stride(from: 2, to: pixels.count, by: 4).map { pixels[$0] }
    }
}

extension MaskRefinementTests {
    static let renderingAvailable: Bool = {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CIContext().createCGImage(image, from: image.extent) != nil
    }()
}
