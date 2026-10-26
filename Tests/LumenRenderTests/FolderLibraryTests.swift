import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import Testing
import UniformTypeIdentifiers
@testable import LumenRender

struct FolderLibraryTests {
    @Test func listsOnlyPhotosInFilenameOrder() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        for name in ["z.png", "a.JPG", "middle.jpeg"] {
            try folder.photo(name: name)
        }
        try Data().write(to: folder.input.appendingPathComponent("h.HEIC"))
        try Data("notes".utf8).write(to: folder.input.appendingPathComponent("notes.txt"))
        let nested = folder.input.appendingPathComponent("nested.png", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("hidden.jpg"))
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        #expect(try await library.photos().map(\.rawValue) == ["a.JPG", "h.HEIC", "middle.jpeg", "z.png"])
    }

    @Test func retainsOneDocumentPerPhoto() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try folder.photo(name: "one.png")
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        async let first = library.editHost(PhotoID("one.png"))
        async let second = library.editHost(PhotoID("one.png"))
        let documents = try await (first, second)
        let firstDocument = try #require(documents.0 as? PhotoDocument)
        let secondDocument = try #require(documents.1 as? PhotoDocument)
        #expect(firstDocument === secondDocument)
    }

    @Test func flagsWithoutMovingOrDeletingThePhoto() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let original = try folder.photo(name: "one.png")
        let data = try Data(contentsOf: original)
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let photo = PhotoID("one.png")
        try await library.flag(photo, reason: "Pocket shot")
        #expect(await library.flagged == [photo: "Pocket shot"])
        #expect(try await library.photos() == [photo])
        #expect(try Data(contentsOf: original) == data)
        #expect(!FileManager.default.fileExists(atPath: folder.output.path))
    }

    @Test func rejectsUnknownPhotosAndUnsafeOutputFolders() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try folder.photo(name: "one.png")
        #expect(throws: LumenError.self) { try FolderLibrary(folder: folder.input, output: folder.input) }
        let alias = folder.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder.input)
        #expect(throws: LumenError.self) { try FolderLibrary(folder: folder.input, output: alias) }
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let unknown = PhotoID("../one.png")
        await #expect(throws: LumenError.self) { try await library.editHost(unknown) }
        await #expect(throws: LumenError.self) { try await library.thumbnail(unknown, maxLongEdge: 32) }
        await #expect(throws: LumenError.self) { try await library.facts(unknown) }
        await #expect(throws: LumenError.self) { try await library.applyAuto(unknown) }
        await #expect(throws: LumenError.self) { try await library.straighten(unknown, degrees: 2) }
        await #expect(throws: LumenError.self) { try await library.flag(unknown, reason: "Missing") }
        await #expect(throws: LumenError.self) { try await library.save(unknown) }
        #expect(await library.flagged.isEmpty)
    }

    @Test func rejectsCollidingExportNames() throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try folder.photo(name: "one.jpg")
        try Data().write(to: folder.input.appendingPathComponent("one.heic"))
        #expect(throws: LumenError.self) { try FolderLibrary(folder: folder.input, output: folder.output) }
    }

    @Test(.enabled(if: !LibraryImages.canRender, "Core Image rendering is available on this host."))
    func unavailableRenderingDoesNotProduceBlackMeasurements() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try folder.photo(name: "one.png")
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let photo = PhotoID("one.png")
        await #expect(throws: LumenError.self) { try await library.facts(photo) }
        await #expect(throws: LumenError.self) { try await library.applyAuto(photo) }
        let document = try #require(try await library.editHost(photo) as? PhotoDocument)
        #expect(await document.layers.isEmpty)
    }
}

@Suite(.enabled(if: LibraryImages.canRender, "Core Image rendering is unavailable on this host."))
struct FolderPhotoTests {
    @Test func thumbnailsAreCappedJPEGsOfTheCurrentEdits() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try folder.photo(name: "one.png", width: 800, height: 600)
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let photo = PhotoID("one.png")
        let before = try await library.thumbnail(photo, maxLongEdge: 100)
        #expect(before.format == .jpeg)
        #expect(before.size == PixelSize(width: 100, height: 75))
        #expect(try LibraryImages.size(of: before.data) == before.size)
        let host = try await library.editHost(photo)
        try await host.apply(Layer(label: "Light", content: .adjustment(values: [.exposure: 1], mask: nil)), assets: AssetStore())
        let after = try await library.thumbnail(photo, maxLongEdge: 100)
        #expect(try LibraryImages.pixel(after.data, x: 50, y: 37).0 > LibraryImages.pixel(before.data, x: 50, y: 37).0 + 20)
        #expect(try await library.thumbnail(photo, maxLongEdge: 2000).size == PixelSize(width: 800, height: 600))
        #expect(try await library.thumbnail(photo, maxLongEdge: 1).size == PixelSize(width: 1, height: 1))
        await #expect(throws: LumenError.self) { try await library.thumbnail(photo, maxLongEdge: 0) }
    }

    @Test func measuresDetailExposureAndClipping() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let sharpURL = try folder.photo(name: "sharp.png", width: 512, height: 384) { x, y in
            let value: UInt8 = (x / 8 + y / 8) % 2 == 0 ? 20 : 235
            return (value, value, value)
        }
        let sharp = try #require(CIImage(contentsOf: sharpURL))
        let blur = sharp.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: sharp.extent)
        try LibraryImages.write(blur, to: folder.input.appendingPathComponent("blur.png"))
        try folder.photo(name: "black.png") { _, _ in (0, 0, 0) }
        try folder.photo(name: "clipped.png") { x, _ in x < 64 ? (3, 3, 3) : (252, 252, 252) }
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let crisp = try await library.facts(PhotoID("sharp.png"))
        let blurred = try await library.facts(PhotoID("blur.png"))
        #expect(crisp.sharpness > blurred.sharpness + 0.3)
        #expect((0...1).contains(crisp.sharpness) && (0...1).contains(blurred.sharpness))
        #expect(abs(crisp.exposure - 0.5) < 0.01)
        #expect(crisp.size == PixelSize(width: 512, height: 384))
        let black = try await library.facts(PhotoID("black.png"))
        #expect(black.sharpness == 0 && black.exposure == 0)
        #expect(black.clippedShadows == 1 && black.clippedHighlights == 0)
        #expect(black.tilt == nil && black.capturedAt == nil)
        let clipped = try await library.facts(PhotoID("clipped.png"))
        #expect(clipped.clippedShadows == 0.5 && clipped.clippedHighlights == 0.5)
    }

    @Test func measuresEditedPixelsAndReadsTheEXIFCaptureDate() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:24 12:34:56",
                                    kCGImagePropertyExifOffsetTimeOriginal: "-04:00"]
        try folder.photo(name: "one.jpg", width: 800, height: 600, orientation: 6, exif: exif)
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let photo = PhotoID("one.jpg")
        let before = try await library.facts(photo)
        #expect(before.size == PixelSize(width: 600, height: 800))
        #expect(before.capturedAt == ISO8601DateFormatter().date(from: "2026-10-24T16:34:56Z"))
        let host = try await library.editHost(photo)
        try await host.apply(Layer(label: "Light", content: .adjustment(values: [.exposure: 1], mask: nil)), assets: AssetStore())
        let after = try await library.facts(photo)
        #expect(after.exposure > before.exposure + 0.05)
        #expect(after.capturedAt == before.capturedAt)
    }

    @Test(.enabled(if: LibraryImages.horizonTilt != nil,
                   "Core Image does not detect a horizon in the synthetic landscape on this host."))
    func findsAKnownRotatedHorizon() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try LibraryImages.write(LibraryImages.horizon, to: folder.input.appendingPathComponent("horizon.png"))
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let facts = try await library.facts(PhotoID("horizon.png"))
        let tilt = try #require(facts.tilt)
        #expect(abs(abs(tilt) - 8) < 2)
    }

    @Test func autoLiftsADarkPhotoAndLeavesBalancedLightNearlyAlone() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try folder.photo(name: "dark.png") { _, _ in (40, 40, 40) }
        try folder.photo(name: "balanced.png") { _, _ in (115, 115, 115) }
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let dark = PhotoID("dark.png"), balanced = PhotoID("balanced.png")
        let before = try await library.facts(dark)
        let label = try await library.applyAuto(dark)
        let document = try #require(try await library.editHost(dark) as? PhotoDocument)
        let layer = try #require(await document.layers.first)
        guard case .adjustment(let values, let mask) = layer.content else {
            Issue.record("Auto must add an adjustment layer.")
            return
        }
        #expect(label.hasPrefix("Auto: ") && layer.label == label)
        #expect(mask == nil && values[.exposure] == 1 && values[.vibrance] == 10)
        #expect(try await library.facts(dark).exposure > before.exposure + 0.05)
        _ = try await library.applyAuto(balanced)
        let balancedDocument = try #require(try await library.editHost(balanced) as? PhotoDocument)
        let balancedLayer = try #require(await balancedDocument.layers.first)
        if case .adjustment(let settings, _) = balancedLayer.content {
            #expect(abs(settings[.exposure] ?? 0) < 0.03)
            #expect(settings.filter { $0.key != .vibrance }.isEmpty)
        } else {
            Issue.record("Auto must add an adjustment layer.")
        }
    }

    @Test func autoUsesPercentilesAndDampedColourStatistics() async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        try folder.photo(name: "cast.png", width: 512, height: 384) { x, _ in
            let value = Double(x) / 511
            return (UInt8(60 + 140 * value), UInt8(40 + 140 * value), UInt8(30 + 140 * value))
        }
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        _ = try await library.applyAuto(PhotoID("cast.png"))
        let document = try #require(try await library.editHost(PhotoID("cast.png")) as? PhotoDocument)
        let layer = try #require(await document.layers.first)
        if case .adjustment(let values, _) = layer.content {
            #expect((values[.blacks] ?? 0) < 0 && (values[.whites] ?? 0) > 0)
            #expect((values[.temperature] ?? 0) < 0)
            #expect(abs(values[.tint] ?? 0) > 0)
            for (key, value) in values {
                let limit = key == .exposure ? 1.0 : (key == .temperature || key == .tint ? 15 : 20)
                #expect(value.isFinite && abs(value) <= limit)
            }
        } else {
            Issue.record("Auto must add an adjustment layer.")
        }
    }

    @Test(arguments: ["one.jpg", "one.png", "one.heic"])
    func savesTheEditedPhotoSidecarAndFlagWithoutTouchingTheOriginal(name: String) async throws {
        let folder = try LibraryFolder()
        defer { folder.remove() }
        let original = try folder.photo(name: name, width: 400, height: 300)
        let originalData = try Data(contentsOf: original)
        let originalDate = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let library = try FolderLibrary(folder: folder.input, output: folder.output)
        let photo = PhotoID(name)
        let label = try await library.applyAuto(photo)
        try await library.straighten(photo, degrees: 5)
        try await library.flag(photo, reason: "Motion blur")
        try await library.save(photo)
        let exportedName = name.hasSuffix("heic") ? "one.jpg" : name
        let exported = folder.output.appendingPathComponent(exportedName)
        let data = try Data(contentsOf: exported)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == (name.hasSuffix("png") ? UTType.png.identifier : UTType.jpeg.identifier))
        let host = try await library.editHost(photo)
        let size = await host.size()
        #expect(try LibraryImages.size(of: data) == size)
        let sidecarURL = exported.appendingPathExtension("lumen.json")
        var sidecar = try JSONDecoder().decode(SavedPhoto.self, from: Data(contentsOf: sidecarURL))
        #expect(sidecar.layers == [label] && sidecar.straighteningAngle == 5 && sidecar.flag == "Motion blur")
        #expect(await library.flagged[photo] == "Motion blur")
        try await library.flag(photo, reason: "Review later")
        try await library.save(photo)
        sidecar = try JSONDecoder().decode(SavedPhoto.self, from: Data(contentsOf: sidecarURL))
        #expect(sidecar.flag == "Review later")
        #expect(try Data(contentsOf: original) == originalData)
        #expect(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
    }
}

private struct SavedPhoto: Decodable {
    var layers: [String]
    var straighteningAngle: Double
    var flag: String?
}

