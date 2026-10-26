import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenRender

@Suite(.enabled(if: LibraryImages.canRender, "Core Image rendering is unavailable on this host."))
struct StraightenedPhotoTests {
    @Test(arguments: [-10.0, 10, 90])
    func keepsAspectAndCanvasSizeConsistent(degrees: Double) async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let url = try folder.photo(name: "one.png", width: 400, height: 300)
        let document = try PhotoDocument(contentsOf: url)
        try await document.straighten(degrees: degrees)
        let size = await document.size()
        #expect(size.width < 400 && size.height < 300)
        #expect(abs(Double(size.width) / Double(size.height) - 4.0 / 3) < 0.01)
        #expect(try await document.render(maxLongEdge: 1000).size == size)
        #expect(try await document.render(region: .whole, maxLongEdge: 1000).size == size)
        let exported = folder.output.appendingPathComponent("straight.png")
        try FileManager.default.createDirectory(at: folder.output, withIntermediateDirectories: true)
        try await document.export(to: exported, format: .png)
        #expect(try LibraryImages.size(of: Data(contentsOf: exported)) == size)
        #expect(try LibraryImages.minimumAlpha(Data(contentsOf: exported)) == 255)
        let region = NormalizedRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let part = try await document.render(region: region, maxLongEdge: 1000)
        #expect(abs(part.size.width * 2 - size.width) <= 2 && part.size.height == size.height)
        await #expect(throws: LumenError.self) { try await document.straighten(degrees: .nan) }
        #expect(await document.straighteningAngle == degrees)
        try await document.straighten(degrees: 0)
        #expect(await document.size() == PixelSize(width: 400, height: 300))
    }

    @Test func masksPatchesAndCropsUseTheStraightenedCanvas() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let document = try PhotoDocument(contentsOf: folder.photo(name: "one.png", width: 400, height: 300))
        try await document.straighten(degrees: 8)
        let size = await document.size()
        let before = try await document.render(maxLongEdge: 1000)
        let assets = AssetStore()
        let mask = MaskData(size: PixelSize(width: 8, height: 6), coverage: (0..<48).map { $0 / 8 < 3 ? 255 : 0 })
        let maskID = await assets.put(.mask(mask))
        try await document.apply(Layer(label: "Top", content: .adjustment(values: [.exposure: 1], mask: maskID)), assets: assets)
        let adjusted = try await document.render(maxLongEdge: 1000)
        let x = size.width / 4, top = size.height / 4, bottom = size.height * 3 / 4
        #expect(try LibraryImages.pixel(adjusted.data, x: x, y: top).0 > LibraryImages.pixel(before.data, x: x, y: top).0 + 20)
        #expect(try abs(Int(LibraryImages.pixel(adjusted.data, x: x, y: bottom).0) - Int(LibraryImages.pixel(before.data, x: x, y: bottom).0)) < 3)
        // A redraw as the agent makes one: the changed thing in the middle of its crop, the photo's grey around it.
        let inside = { (x: Int, y: Int) in (16..<48).contains(x) && (8..<40).contains(y) }
        let patchURL = try folder.photo(name: "patch.png", width: 64, height: 48) { x, y in inside(x, y) ? (220, 30, 30) : (90, 90, 90) }
        let patchID = await assets.put(.image(EncodedImage(data: try Data(contentsOf: patchURL), format: .png,
                                                          size: PixelSize(width: 64, height: 48))))
        let coverageID = await assets.put(.mask(MaskData(size: PixelSize(width: 64, height: 48),
                                                         coverage: (0..<(64 * 48)).map { inside($0 % 64, $0 / 64) ? 255 : 0 })))
        // Below the brightened top half, so the patch's surroundings are the photo's own grey.
        let region = NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        try await document.apply(Layer(label: "Bottom right", content: .patch(image: patchID, mask: coverageID, rect: region)), assets: assets)
        let patched = try await document.render(maxLongEdge: 1000)
        let pixel = try LibraryImages.pixel(patched.data, x: size.width * 3 / 4, y: bottom)
        // A new colour beside a flat background keeps its strength.
        #expect(pixel.0 > 200 && pixel.1 < 50, "\(pixel)")
        try await document.apply(Layer(label: "Crop", content: .crop(region)), assets: assets)
        let cropped = try await document.render(maxLongEdge: 1000)
        #expect(abs(cropped.size.width * 2 - size.width) <= 2 && abs(cropped.size.height * 2 - size.height) <= 2)
        #expect(await document.size() == size)
    }
}

