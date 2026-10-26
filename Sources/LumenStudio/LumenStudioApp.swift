import AppKit
import SwiftUI

@main
enum StudioLaunch {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            LumenStudioApp.main()
        } else if arguments == ["--help"] || arguments == ["-h"] {
            print(StudioScriptArguments.usage)
        } else {
            StudioScriptApplication.main(arguments)
        }
    }
}

struct LumenStudioApp: App {
    @State private var model = StudioModel()
    @NSApplicationDelegateAdaptor(StudioApplicationDelegate.self) private var delegate

    var body: some Scene {
        Window("Lumen Studio", id: "studio") {
            StudioView(model: model)
                .onAppear { delegate.model = model }
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

@MainActor
final class StudioApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: StudioModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model?.close()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
