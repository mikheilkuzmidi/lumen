import Foundation
import LumenCore
import Testing
@testable import LumenRender

/// The CC0 lake photo in Fixtures/library was rotated 4° on purpose; levelling it must leave no tilt.
struct HorizonTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    @Test func aTiltedHorizonIsMeasuredAndLevelled() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = input.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: input) }
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("library/kayaks-on-a-mountain-lake-tilted.jpg"),
                                         to: input.appendingPathComponent("lake.jpg"))
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("photos/kayaks-on-a-mountain-lake.jpg"),
                                         to: input.appendingPathComponent("level.jpg"))
        let library = try FolderLibrary(folder: input, output: output)
        let lake = PhotoID("lake.jpg")
        let tilt = try #require(try await library.facts(lake).tilt)
        #expect(abs(tilt - 4) < 1, "measured \(tilt)°")
        #expect(try await library.facts(PhotoID("level.jpg")).tilt == nil, "the original is level")
        try await library.straighten(lake, degrees: -tilt)
        #expect(try await library.facts(lake).tilt == nil, "levelled")
    }
}
