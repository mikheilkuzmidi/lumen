import AppKit
import SwiftUI
import LumenCore
import Observation

/// Owns library windows and the photo windows opened from their results.
@MainActor @Observable
final class StudioLibraryWindows {
    var focusedPhoto: StudioModel?
    @ObservationIgnored private var windows: [UUID: LibraryWindowController] = [:]
    @ObservationIgnored private var photoWindows: [String: UUID] = [:]

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open a photo library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.openFolder(url) }
        }
    }

    func openFolder(_ url: URL) {
        let model = StudioLibraryModel()
        let id = UUID()
        let view = StudioLibraryView(model: model, openFolder: { [weak self] in self?.openFolder($0) },
                                    openPhoto: { [weak self] photo in self?.openPhoto(photo, from: model) })
        let controller = makeWindow(id: id, title: url.lastPathComponent, view: view, focusedPhoto: nil) {
            await model.close()
        }
        windows[id] = controller
        controller.showWindow(nil)
        Task {
            do { try await model.openFolder(url) }
            catch { model.issue = error.localizedDescription }
        }
    }

    private func openPhoto(_ photo: PhotoID, from library: StudioLibraryModel) {
        guard !library.isRunning else { return }
        let key = "\(ObjectIdentifier(library)):\(photo.rawValue)"
        if let id = photoWindows[key] {
            windows[id]?.showWindow(nil)
            return
        }
        let model = StudioModel()
        let id = UUID()
        photoWindows[key] = id
        Task { [self, library] in
            do {
                try await library.openPhoto(photo, in: model)
                model.photoDidChange = { [weak library] in library?.refreshPhoto(photo) }
                let view = StudioView(model: model, openFolder: { [weak self] in self?.openFolder($0) })
                let controller = makeWindow(id: id, title: photo.rawValue, view: view, focusedPhoto: model) {
                    await model.close()
                    library.refreshPhoto(photo)
                    self.photoWindows[key] = nil
                }
                windows[id] = controller
                controller.showWindow(nil)
            } catch { photoWindows[key] = nil; library.issue = error.localizedDescription }
        }
    }

    private func makeWindow<Content: View>(id: UUID, title: String, view: Content, focusedPhoto: StudioModel?,
                                           close: @escaping @MainActor () async -> Void) -> LibraryWindowController {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 980, height: 680)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark).tint(StudioStyle.accent))
        window.center()
        return LibraryWindowController(window: window, focus: { [weak self] in self?.focusedPhoto = focusedPhoto }, close: { [weak self] in
            await close()
            if self?.focusedPhoto === focusedPhoto { self?.focusedPhoto = nil }
            self?.windows[id] = nil
        })
    }

    func close() async {
        for controller in Array(windows.values) { await controller.cleanUp() }
        windows.removeAll()
        photoWindows.removeAll()
    }
}

@MainActor
private final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private let focus: () -> Void
    private let close: () async -> Void
    private var closed = false

    init(window: NSWindow, focus: @escaping () -> Void, close: @escaping () async -> Void) {
        self.focus = focus
        self.close = close
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowDidBecomeMain(_ notification: Notification) { focus() }
    func windowWillClose(_ notification: Notification) { Task { await cleanUp() } }
    func cleanUp() async {
        guard !closed else { return }
        closed = true
        await close()
    }
}
