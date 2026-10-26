import AppKit
import SwiftUI

/// Captures the library and a retained result in an offscreen window.
@MainActor
final class StudioLibraryScriptApplication {
    private let arguments: StudioScriptArguments
    private let script: StudioLibraryScript
    private var window: NSPanel?
    private var status: Int32 = 1

    private init(arguments: StudioScriptArguments, script: StudioLibraryScript) {
        self.arguments = arguments
        self.script = script
    }

    static func main(_ arguments: StudioScriptArguments) {
        let app = NSApplication.shared
        do {
            let script = try StudioLibraryScript.parse(Data(contentsOf: arguments.script))
            let application = StudioLibraryScriptApplication(arguments: arguments, script: script)
            Task { await application.run() }
            app.run()
            withExtendedLifetime(application) { exit(application.status) }
        } catch {
            writeError(error, arguments: arguments)
            exit(1)
        }
    }

    private func run() async {
        let model = StudioLibraryModel()
        let photo = StudioModel()
        do {
            try prepareOutput()
            let runner = StudioLibraryScriptRunner(model: model, photoModel: photo, script: script,
                                                  scriptURL: arguments.script, output: arguments.output)
            try await runner.run { snapshot in
                if self.window == nil { self.openWindow(model: model) }
                if snapshot == .photo, let window = self.window {
                    window.contentView = NSHostingView(rootView: StudioView(model: photo, activatesBackend: false)
                        .preferredColorScheme(.dark).tint(StudioStyle.accent)
                        .frame(width: self.script.window.width, height: self.script.window.height))
                }
                try await Task.sleep(for: .milliseconds(250))
                try self.capture(snapshot)
            }
            status = 0
        } catch { Self.writeError(error, arguments: arguments) }
        await model.close()
        await photo.close()
        window?.orderOut(nil)
        window = nil
        NSApplication.shared.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApplication.shared.postEvent(event, atStart: true)
        }
    }

    private func openWindow(model: StudioLibraryModel) {
        let size = NSSize(width: script.window.width, height: script.window.height)
        let panel = LibraryScriptWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Lumen Library"
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: StudioLibraryView(model: model, activatesBackend: false)
            .preferredColorScheme(.dark).tint(StudioStyle.accent).frame(width: size.width, height: size.height))
        let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        panel.setFrameOrigin(NSPoint(x: right + size.width + 100, y: 0))
        window = panel
        panel.orderBack(nil)
    }

    private func capture(_ snapshot: LibrarySnapshot) throws {
        guard let view = window?.contentView else { throw StudioScriptError.message("No library window to capture.") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw StudioScriptError.message("Couldn't allocate the library snapshot.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw StudioScriptError.message("Couldn't encode the library snapshot.")
        }
        try data.write(to: arguments.output.appendingPathComponent(snapshot.filename), options: .atomic)
    }

    private func prepareOutput() throws {
        let output = arguments.output.resolvingSymlinksInPath().standardizedFileURL
        let folder = script.folderURL(relativeTo: arguments.script).resolvingSymlinksInPath().standardizedFileURL
        let results = (script.outputURL(relativeTo: arguments.script) ?? folder.appendingPathComponent("Lumen")).resolvingSymlinksInPath().standardizedFileURL
        guard output != folder, output != results else {
            throw StudioScriptError.message("Keep the capture folder separate from the source and results folders.")
        }
        let names = LibrarySnapshot.allCases.map(\.filename) + ["timeline.txt", "summary.json", "error.txt"]
        guard !names.contains(where: { output.appendingPathComponent($0) == arguments.script.resolvingSymlinksInPath().standardizedFileURL }) else {
            throw StudioScriptError.message("The capture folder would overwrite the library script.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in names {
            let url = output.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private static func writeError(_ error: any Error, arguments: StudioScriptArguments) {
        let message = error.localizedDescription + "\n"
        FileHandle.standardError.write(Data(message.utf8))
        let output = arguments.output
        guard output.appendingPathComponent("error.txt").resolvingSymlinksInPath() != arguments.script.resolvingSymlinksInPath() else { return }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? message.write(to: output.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
    }
}

private final class LibraryScriptWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
