import AppKit
import SwiftUI

/// "Lumen" at the left edge of a window's top bar. The window's own buttons stay hidden until the pointer is over that
/// corner; then they fade in and the name slides right to make room, as in Photoeditor.
struct StudioWindowTitle: View {
    @State private var showsButtons = false

    var body: some View {
        Text("Lumen").font(StudioStyle.title).foregroundStyle(StudioStyle.textSecondary)
            .padding(.leading, showsButtons ? 64 : 0)
            .animation(.easeOut(duration: 0.18), value: showsButtons)
            .background(alignment: .leading) {
                WindowButtonsReveal(showsButtons: $showsButtons)
                    .frame(width: 96, height: StudioStyle.topBarHeight)
                    .offset(x: -StudioStyle.barInset)
                    .allowsHitTesting(false)
            }
    }
}

/// Tracks the pointer over the window's top-left corner and shows or hides the close, minimise and zoom buttons there.
private struct WindowButtonsReveal: NSViewRepresentable {
    @Binding var showsButtons: Bool

    func makeNSView(context: Context) -> CornerView {
        let view = CornerView()
        view.changed = { inside in if showsButtons != inside { showsButtons = inside } }
        return view
    }

    func updateNSView(_ view: CornerView, context: Context) {
        view.changed = { inside in if showsButtons != inside { showsButtons = inside } }
    }

    final class CornerView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var inside = false
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // The window puts its buttons back on some changes of state: hide them again after each.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification,
                         NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply(animated: false) }
                })
            }
            apply(animated: false)
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }

        private func set(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            apply(animated: true)
            changed(value)
        }

        private func apply(animated: Bool) {
            guard let window, window.styleMask.contains(.titled) else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            let alpha: CGFloat = inside || window.styleMask.contains(.fullScreen) ? 1 : 0
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    for button in buttons { button.animator().alphaValue = alpha }
                }
            } else {
                for button in buttons { button.alphaValue = alpha }
            }
        }
    }
}

/// A question asked before planning, with its options as chips and the recommended one marked. Library questions
/// live in the side review; over a photo they float above the instruction field.
struct StudioQuestionCard: View {
    let question: String
    let options: [String]
    let recommended: Int
    var floating = false
    var disabled = false
    let answer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble").foregroundStyle(StudioStyle.accent)
                Text(question).font(StudioStyle.title).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack { choices }
                VStack(alignment: .leading) { choices }
            }
        }
        .padding(floating ? 14 : StudioStyle.gutter).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioStyle.cardRadius, style: .continuous).strokeBorder(StudioStyle.line)
        }
        .shadow(color: .black.opacity(floating ? 0.35 : 0), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question")
    }

    private var choices: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            StudioChip(isSelected: index == recommended, action: { answer(option) }) {
                HStack(spacing: 6) {
                    Text(option).font(StudioStyle.body)
                    if index == recommended { Text("Recommended").font(StudioStyle.caption).foregroundStyle(StudioStyle.accent) }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: StudioStyle.radius).strokeBorder(StudioStyle.line) }
            .disabled(disabled)
        }
    }
}
