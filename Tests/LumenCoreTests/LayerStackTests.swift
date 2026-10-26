import Foundation
import Testing
@testable import LumenCore

@Suite("Layer stack")
struct LayerStackTests {
    @Test func changesUndoAndRedoAsWholeStacks() {
        let sky = Layer(label: "Sky", content: .adjustment(values: [.exposure: -1], mask: AssetID()))
        let coat = Layer(label: "Coat", content: .patch(image: AssetID(), mask: AssetID(), rect: .whole))
        var stack = LayerStack(layers: [sky])
        var states = [stack.layers]
        let labels = ["Add Coat", "Disable Sky", "Change opacity of Coat", "Remove Sky", "Disable Coat", "Enable Coat"]

        stack.append(coat)
        states.append(stack.layers)
        stack.setEnabled(false, for: sky.id)
        states.append(stack.layers)
        stack.setOpacity(0.25, for: coat.id)
        states.append(stack.layers)
        stack.remove(id: sky.id)
        states.append(stack.layers)
        stack.setEnabled(false, for: coat.id)
        states.append(stack.layers)
        stack.setEnabled(true, for: coat.id)
        states.append(stack.layers)

        for index in labels.indices.reversed() {
            #expect(stack.canUndo)
            #expect(stack.undoLabel == labels[index])
            #expect(stack.undo() == labels[index])
            #expect(stack.layers == states[index])
            #expect(stack.redoLabel == labels[index])
        }
        #expect(!stack.canUndo)
        #expect(stack.undoLabel == nil)
        #expect(stack.undo() == nil)

        for index in labels.indices {
            #expect(stack.canRedo)
            #expect(stack.redoLabel == labels[index])
            #expect(stack.redo() == labels[index])
            #expect(stack.layers == states[index + 1])
            #expect(stack.undoLabel == labels[index])
        }
        #expect(!stack.canRedo)
        #expect(stack.redoLabel == nil)
        #expect(stack.redo() == nil)
    }

    @Test func layersCanBeFoundAndMissingIDsDoNothing() {
        let layer = Layer(label: "Crop", content: .crop(.whole))
        var stack = LayerStack(layers: [layer])
        let missing = UUID()
        #expect(stack.layer(id: layer.id) == layer)
        #expect(stack.layer(id: missing) == nil)
        stack.remove(id: missing)
        stack.setEnabled(false, for: missing)
        stack.setOpacity(0.5, for: missing)
        #expect(stack == LayerStack(layers: [layer]))
    }

    @Test(arguments: [-2.0, 2.0, -Double.infinity, Double.infinity])
    func opacityIsClamped(opacity: Double) {
        let layer = Layer(label: "Sky", content: .adjustment(values: [.exposure: -1], mask: nil), opacity: 0.5)
        var stack = LayerStack(layers: [layer])
        stack.setOpacity(opacity, for: layer.id)
        #expect(stack.layer(id: layer.id)?.opacity == (opacity < 0 ? 0 : 1))
        #expect(stack.undo() == "Change opacity of Sky")
        #expect(stack.layers == [layer])
        #expect(stack.redo() == "Change opacity of Sky")
        #expect(stack.layer(id: layer.id)?.opacity == (opacity < 0 ? 0 : 1))
    }

    @Test func noChangesKeepRedoAndDoNotAddHistory() {
        let layer = Layer(label: "Sky", content: .crop(.whole))
        var stack = LayerStack(layers: [layer])
        stack.setEnabled(false, for: layer.id)
        stack.undo()
        let before = stack
        stack.setEnabled(true, for: layer.id)
        stack.setOpacity(1, for: layer.id)
        stack.setOpacity(2, for: layer.id)
        stack.setOpacity(.nan, for: layer.id)
        stack.remove(id: UUID())
        #expect(stack == before)
        #expect(stack.redo() == "Disable Sky")
    }

    @Test(arguments: ["append", "remove", "enabled", "opacity"])
    func aNewChangeAfterUndoDropsRedo(change: String) {
        let layer = Layer(label: "Sky", content: .crop(.whole))
        var stack = LayerStack(layers: [layer])
        stack.setOpacity(0.5, for: layer.id)
        stack.undo()
        #expect(stack.canRedo)

        switch change {
        case "append": stack.append(Layer(label: "Coat", content: .crop(.whole)))
        case "remove": stack.remove(id: layer.id)
        case "enabled": stack.setEnabled(false, for: layer.id)
        default: stack.setOpacity(0.25, for: layer.id)
        }

        #expect(!stack.canRedo)
        #expect(stack.redoLabel == nil)
        #expect(stack.redo() == nil)
        stack.undo()
        #expect(stack.layers == [layer])
        #expect(!stack.canUndo)
    }

    @Test func codingPreservesLayersAndBothHistories() throws {
        let layer = Layer(label: "Sky", content: .adjustment(values: [.exposure: -1], mask: AssetID()))
        let crop = Layer(label: "Crop", content: .crop(NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        var stack = LayerStack()
        stack.append(layer)
        stack.append(crop)
        stack.setOpacity(0.25, for: layer.id)
        stack.setEnabled(false, for: crop.id)
        stack.remove(id: layer.id)
        stack.undo()
        stack.undo()

        var restored = try JSONDecoder().decode(LayerStack.self, from: JSONEncoder().encode(stack))
        #expect(restored == stack)
        #expect(restored.undoLabel == "Change opacity of Sky")
        #expect(restored.redoLabel == "Disable Crop")

        while stack.canUndo {
            #expect(restored.undo() == stack.undo())
            #expect(restored == stack)
        }
        while stack.canRedo {
            #expect(restored.redo() == stack.redo())
            #expect(restored == stack)
        }
    }

    @Test func aStackWithoutSavedHistoryStillDecodes() throws {
        let restored = try JSONDecoder().decode(LayerStack.self, from: Data(#"{"layers":[]}"#.utf8))
        #expect(restored == LayerStack())
        #expect(!restored.canUndo)
        #expect(!restored.canRedo)
    }
}
