import CoreGraphics
import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenRender

/// Camera RAW: a CC0 DNG from raw.pixls.us (a Samsung Galaxy S10 phone, SM-G973U, 4016 × 1892) is developed, edited, listed in
/// a library and exported as JPEG, the original untouched.
struct RawPhotoTests {
    static let dng = Bundle.module.url(forResource: "samsung-galaxy-s10", withExtension: "dng", subdirectory: "RAW")!

    @Test func knowsRawFilesAndWhatTheyExportAs() {
        for name in ["a.dng", "b.NEF", "c.cr3", "d.ARW", "e.raf", "f.orf", "g.rw2"] {
            #expect(PhotoFormats.isRaw(URL(fileURLWithPath: name)), "\(name)")
            #expect(PhotoFormats.opens(URL(fileURLWithPath: name)), "\(name)")
        }
        #expect(!PhotoFormats.isRaw(URL(fileURLWithPath: "a.jpg")))
        #expect(!PhotoFormats.opens(URL(fileURLWithPath: "notes.txt")))
        #expect(PhotoFormats.exportName(for: URL(fileURLWithPath: "/x/shot.CR3")) == "shot.jpg")
        #expect(PhotoFormats.exportName(for: URL(fileURLWithPath: "/x/shot.heic")) == "shot.jpg")
        #expect(PhotoFormats.exportName(for: URL(fileURLWithPath: "/x/shot.png")) == "shot.png")
        #expect(PhotoFormats.exportName(for: URL(fileURLWithPath: "/x/shot.jpeg")) == "shot.jpeg")
    }

    @Test(.enabled(if: LibraryImages.canRender))
    func developsARawAtFullSizeAndRendersItForTheModels() async throws {
        let document = try PhotoDocument(contentsOf: Self.dng)
        #expect(await document.size() == PixelSize(width: 4016, height: 1892))
        let preview = try await document.render(maxLongEdge: 1024)
        #expect(preview.size.width == 1024)
        #expect(abs(Double(preview.size.height) - 1024 * 1892 / 4016) <= 1)
        // A developed daylight photo, not a black or blank frame: mid-tones and real contrast.
        let source = try #require(CGImageSourceCreateWithData(preview.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let lumas = try LibraryImages.lumas(of: image)
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let spread = (lumas.max() ?? 0) - (lumas.min() ?? 0)
        #expect(mean > 40 && mean < 215, "mean \(mean)")
        #expect(spread > 120, "spread \(spread)")
    }

    @Test(.enabled(if: LibraryImages.canRender))
    func aLibraryListsRawAndExportsItAsJpegWithoutTouchingTheOriginal() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let original = folder.input.appendingPathComponent("church.dng")
        try FileManager.default.copyItem(at: Self.dng, to: original)
        let originalData = try Data(contentsOf: original)
        try folder.photo(name: "beside.jpg")
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let photo = PhotoID("church.dng")
        #expect(try await library.photos() == [PhotoID("beside.jpg"), photo])
        _ = try await library.applyAuto(photo)
        try await library.straighten(photo, degrees: 2)
        try await library.save(photo)
        let exported = folder.output.appendingPathComponent("church.jpg")
        let data = try Data(contentsOf: exported)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let size = await (try library.editHost(photo)).size()
        #expect(try LibraryImages.size(of: data) == size)
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathExtension("lumen.json").path))
        #expect(try Data(contentsOf: original) == originalData)
    }
}

private extension LibraryImages {
    /// Rec. 709 luma of every pixel, 0–255.
    static func lumas(of image: CGImage) throws -> [Double] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            0.2126 * Double(bytes[$0]) + 0.7152 * Double(bytes[$0 + 1]) + 0.0722 * Double(bytes[$0 + 2])
        }
    }
}
