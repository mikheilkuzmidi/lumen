import AppKit
import SwiftUI

/// Runs an offscreen window without activating the application or accepting input.
@MainActor
final class StudioScriptApplication {
    private let arguments: StudioScriptArguments
    private let script: StudioScript
    private var window: NSPanel?
    private var status: Int32 = 1

    private init(arguments: StudioScriptArguments, script: StudioScript) {
        self.arguments = arguments
        self.script = script
    }

    static func main(_ arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        do {
            let options = try StudioScriptArguments(arguments)
            try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
            let script = try StudioScript.parse(Data(contentsOf: options.script))
            let application = StudioScriptApplication(arguments: options, script: script)
            Task { await application.run() }
            app.run()
            withExtendedLifetime(application) { exit(application.status) }
        } catch {
            writeError(error, output: StudioScriptArguments.errorOutput(in: arguments))
            exit(1)
        }
    }

    private func run() async {
        let model = StudioModel()
        do {
            try removePreviousOutput()
            let runner = StudioScriptRunner(model: model, script: script, scriptURL: arguments.script, output: arguments.output)
            try await runner.run { snapshot in
                if self.window == nil { self.openWindow(model: model) }
                // Let layout and timeline scrolling settle before freezing an animation frame.
                try await Task.sleep(for: snapshot == .selected ? .milliseconds(600) : .milliseconds(180))
                model.snapshotDate = Date()
                try await Task.sleep(for: .milliseconds(50))
                defer { model.snapshotDate = nil }
                try self.capture(snapshot)
            }
            status = 0
        } catch {
            Self.writeError(error, output: arguments.output)
        }
        window?.orderOut(nil)
        window = nil
        NSApplication.shared.stop(nil)
        // Wake the application loop so a stopped accessory application can return from run().
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                         timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApplication.shared.postEvent(event, atStart: true)
        }
    }

    private func openWindow(model: StudioModel) {
        let size = NSSize(width: script.window.width, height: script.window.height)
        let panel = StudioScriptWindow(contentRect: NSRect(origin: .zero, size: size),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Lumen Studio"
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        let root = StudioView(model: model)
            .preferredColorScheme(.dark)
            .tint(StudioStyle.accent)
            .frame(width: size.width, height: size.height)
        panel.contentView = NSHostingView(rootView: root)
        let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        panel.setFrameOrigin(NSPoint(x: right + size.width + 100, y: 0))
        window = panel
        panel.orderBack(nil)
    }

    private func capture(_ snapshot: StudioSnapshot) throws {
        guard let view = window?.contentView else { throw StudioScriptError.message("No window content to capture.") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw StudioScriptError.message("Couldn't allocate the window snapshot.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw StudioScriptError.message("Couldn't encode the window snapshot.")
        }
        try png.write(to: arguments.output.appendingPathComponent(snapshot.filename), options: .atomic)
    }

    private func removePreviousOutput() throws {
        let names = StudioSnapshot.allCases.map(\.filename) + ["result.jpg", "timeline.txt", "error.txt"]
        let inputs = [arguments.script, script.photoURL(relativeTo: arguments.script)].map { $0.resolvingSymlinksInPath() }
        for name in names where inputs.contains(arguments.output.appendingPathComponent(name).resolvingSymlinksInPath()) {
            throw StudioScriptError.message("The output folder would overwrite an input file (\(name)). Choose another folder.")
        }
        for name in names {
            let url = arguments.output.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private static func writeError(_ error: any Error, output: URL?) {
        let message = error.localizedDescription + "\n"
        FileHandle.standardError.write(Data(message.utf8))
        guard let output else { return }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try message.write(to: output.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Couldn't write error.txt: \(error.localizedDescription)\n".utf8))
        }
    }
}

private final class StudioScriptWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
