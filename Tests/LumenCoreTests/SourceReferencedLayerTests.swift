import Foundation
import Testing
import LumenCore

struct SourceReferencedLayerTests {
    @Test func legacyLayerBytesStayUnchangedAndNewFlagSurvivesHistoryReplay() throws {
        let old = Data(#"{"content":{"crop":{"_0":{"height":1,"width":1,"x":0,"y":0}}},"id":"10000000-0000-0000-0000-000000000001","isEnabled":true,"label":"Crop","opacity":1}"#.utf8)
        let decoded = try JSONDecoder().decode(Layer.self, from: old)
        #expect(decoded.sourceReferenced == nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(decoded) == old, "Omitting a nil flag must preserve legacy layer bytes")
        var material = Layer(label: "Material", content: .patch(image: AssetID(), mask: AssetID(), rect: .whole),
                             precompositedEdges: true, sourceReferenced: true)
        let data = try encoder.encode(material)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sourceReferenced"] as? Bool == true)
        #expect(try JSONDecoder().decode(Layer.self, from: data) == material)
        var stack = LayerStack(); stack.append(material); stack.setOpacity(0.5, for: material.id); stack.undo()
        var restored = try JSONDecoder().decode(LayerStack.self, from: encoder.encode(stack))
        #expect(restored.layers[0].sourceReferenced == true)
        restored.redo(); material.opacity = 0.5
        #expect(restored.layers == [material])
    }
}
