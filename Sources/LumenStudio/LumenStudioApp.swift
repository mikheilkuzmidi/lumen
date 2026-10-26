import SwiftUI

@main
struct LumenStudioApp: App {
    @State private var model = StudioModel()

    var body: some Scene {
        Window("Lumen Studio", id: "studio") {
            StudioView(model: model)
                .preferredColorScheme(.dark)
                .tint(StudioStyle.accent)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Photo…", action: model.choosePhoto)
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: model.undo)
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo", action: model.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Photo…", action: model.chooseExport)
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
            }
        }

        Settings {
            StudioSettingsView()
                .preferredColorScheme(.dark)
                .tint(StudioStyle.accent)
        }
    }
}
