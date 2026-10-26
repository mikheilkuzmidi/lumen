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
    @State private var libraries = StudioLibraryWindows()
    @NSApplicationDelegateAdaptor(StudioApplicationDelegate.self) private var delegate

    var body: some Scene {
        Window("Lumen Studio", id: "studio") {
            StudioView(model: model, openFolder: libraries.openFolder)
                .onAppear { delegate.model = model; delegate.libraries = libraries; libraries.focusedPhoto = model }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { notification in
                    if let window = notification.object as? NSWindow,
                       window.identifier?.rawValue == "studio" || window.title == "Lumen Studio" {
                        libraries.focusedPhoto = model
                    }
                }
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
                Button("Open Folder…", action: libraries.chooseFolder)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { libraries.focusedPhoto?.undo() }
                    .keyboardShortcut("z")
                    .disabled(libraries.focusedPhoto?.canUndo != true)
                Button("Redo") { libraries.focusedPhoto?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(libraries.focusedPhoto?.canRedo != true)
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Photo…") { libraries.focusedPhoto?.chooseExport() }
                    .keyboardShortcut("e")
                    .disabled(libraries.focusedPhoto?.canExport != true)
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
    weak var libraries: StudioLibraryWindows?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model?.close()
            await libraries?.close()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
