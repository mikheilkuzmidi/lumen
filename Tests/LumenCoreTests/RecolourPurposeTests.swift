import Foundation
import Testing
@testable import LumenCore

struct RecolourPurposeTests {
    @Test(arguments: ["Recolour the black jacket bright yellow, keeping its hood and folds",
                      "Recolor the white T-shirt solid black instead of white",
                      "Dye the red leather coat navy, preserving its cut"])
    func explicitColourReplacementUsesTheNarrowPath(prompt: String) {
        #expect(EditAgent.isRecolourPrompt(prompt))
    }

    @Test(arguments: ["Dress the man as a knight", "Replace the shirt with a leather jacket", "A wooden chair",
                      "Recolour the shirt red and add a logo", "Recolour it brown and make it wooden",
                      "Recolour it blue and reshape the sleeves"])
    func geometryMaterialsAndOtherRegenerationKeepTheirPath(prompt: String) {
        #expect(!EditAgent.isRecolourPrompt(prompt))
    }

    @Test func savedLayersWithoutTheNewMarkerRemainReadable() throws {
        let original = Layer(label: "Earlier layer", content: .crop(.whole))
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["precompositedEdges"] == nil)
        #expect(try JSONDecoder().decode(Layer.self, from: data) == original)
        var prepared = original
        prepared.precompositedEdges = true
        #expect(try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(prepared)).precompositedEdges == true)
    }
}
