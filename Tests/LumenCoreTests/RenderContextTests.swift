import Foundation
import Testing
import LumenCore

struct RenderContextTests {
    @Test func hostContextNeverChangesImageBytesOrSerializedReplayShape() throws {
        let plain = EncodedImage(data: Data([1, 2, 3]), format: .png, size: PixelSize(width: 2, height: 3))
        var first = plain, second = plain
        first.renderContextID = UUID(); second.renderContextID = UUID()
        #expect(first.renderContextID != second.renderContextID)
        #expect(first == second && first == plain)
        #expect(first.dataURL == plain.dataURL && first.data == plain.data)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recorded = try encoder.encode(first)
        #expect(recorded == (try encoder.encode(plain)))
        #expect(recorded == (try encoder.encode(second)))
        let object = try #require(JSONSerialization.jsonObject(with: recorded) as? [String: Any])
        #expect(Set(object.keys) == ["data", "format", "size"])
        let decoded = try JSONDecoder().decode(EncodedImage.self, from: recorded)
        #expect(decoded == plain && decoded.renderContextID == nil)
    }
}
