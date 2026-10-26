import AppKit
import SwiftUI
import LumenCore

struct StudioCanvas: View {
    @Bindable var model: StudioModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let size = fittedSize(in: geometry.size)
                let edge = Int(ceil(max(size.width, size.height) * displayScale))
                ZStack {
                    StudioStyle.canvas
                    if let image = model.showsOriginal ? model.original : model.preview {
                        ScrollView([.horizontal, .vertical]) {
                            PhotoSurface(model: model, image: image)
                                .frame(width: size.width, height: size.height)
                                .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .defaultScrollAnchor(.center, for: .alignment)
                        .overlay(alignment: .topLeading) {
                            if model.showsOriginal {
                                Text("Original")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(20)
                                    .allowsHitTesting(false)
                            }
                        }
                    } else {
                        emptyCanvas
                    }
                }
                .task(id: "\(model.photoURL?.path ?? ""):\(edge)") {
                    await model.renderPreview(maxLongEdge: max(1, edge))
                }
            }
            .clipped()
            canvasControls
        }
        .background(StudioStyle.canvas)
    }

    private func fittedSize(in viewport: CGSize) -> CGSize {
        guard let image = model.showsOriginal ? model.original : model.preview,
              image.size.width > 0, image.size.height > 0 else { return viewport }
        let scale = min(max(1, viewport.width - 64) / image.size.width,
                        max(1, viewport.height - 64) / image.size.height) * model.zoom
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private var emptyCanvas: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(StudioStyle.line, lineWidth: 1)
                    .frame(width: 76, height: 76)
                Image(systemName: "viewfinder")
                    .font(.system(size: 33, weight: .ultraLight))
                    .foregroundStyle(StudioStyle.accent)
                Circle().fill(StudioStyle.accent).frame(width: 5, height: 5)
            }
            .padding(.bottom, 30)
            Text("A little light.\nA different perspective.")
                .font(.system(size: 34, weight: .regular, design: .serif))
                .tracking(-0.6).multilineTextAlignment(.center).lineSpacing(3)
            Text("Open a photo. Describe a change.\nKeep every step as a layer.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(6)
                .padding(.top, 18).padding(.bottom, 28)
            if model.phase == .opening {
                ProgressView("Opening photo…").controlSize(.small)
            } else {
                Button(action: model.choosePhoto) {
                    HStack(spacing: 14) {
                        Text("Open Photo")
                        Text("⌘O").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).disabled(model.isBusy)
                Text("or drop a photo here")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 12)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canvasControls: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.dashed").font(.system(size: 11))
            Text(model.area == nil ? "Drag on the photo to choose an area" : "Drag to move · Corners to resize · Esc to clear")
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button { model.zoom = max(0.5, model.zoom / 1.25) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Zoom out")
            Button { model.zoom = 1 } label: {
                Text(model.zoom == 1 ? "Fit" : String(format: "%.0f%%", model.zoom * 100))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 38)
            }
            .help("Fit photo to canvas. Percentages are relative to fit.")
            Button { model.zoom = min(4, model.zoom * 1.25) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Zoom in")
            Rectangle().fill(StudioStyle.line).frame(width: 1, height: 14)
            Button { model.compare.toggle() } label: {
                Label("Compare", systemImage: "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.showsOriginal ? StudioStyle.accent : Color.secondary)
            }
            .help("Show the original, or hold Space while not typing")
            .accessibilityValue(model.showsOriginal ? "Original" : "Edited")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24).frame(height: 38)
        .disabled(model.preview == nil)
    }
}

private struct PhotoSurface: View {
    @Bindable var model: StudioModel
    let image: NSImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var interaction: AreaInteraction?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .accessibilityLabel(model.showsOriginal ? "Original photo" : "Edited photo")
                if !model.showsOriginal {
                    ForEach(model.regions) { region in
                        RegionOverlay(region: region, snapshotDate: model.snapshotDate)
                            .transition(.opacity)
                    }
                    .allowsHitTesting(false)
                    if let area = model.area {
                        AreaOverlay(area: area, snapshotDate: model.snapshotDate)
                            .allowsHitTesting(false)
                    }
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(areaGesture(in: geometry.size))
                    .allowsHitTesting(!model.isBusy && !model.showsOriginal)
                    .accessibilityLabel("Photo area selection")
                    .accessibilityHint("Drag a box to choose where Lumen looks. Drag inside to move it, or drag a corner to resize it. Press Escape to clear.")
            }
            .clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: model.regions.map(\.id))
        }
    }

    private func areaGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if interaction == nil {
                    interaction = AreaInteraction(start: value.startLocation, area: model.area, size: size)
                }
                model.area = interaction?.rect(at: value.location, size: size)
            }
            .onEnded { _ in
                if let area = model.area, area.width * size.width < 6 || area.height * size.height < 6 {
                    model.area = nil
                }
                interaction = nil
            }
    }
}

private struct AreaOverlay: View {
    let area: NormalizedRect
    let snapshotDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let rect = area.rect(in: geometry.size)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geometry.size))
                path.addRect(rect)
            }
            .fill(.black.opacity(0.48), style: FillStyle(eoFill: true))
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                let phase = reduceMotion ? 0 : (snapshotDate ?? timeline.date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * -18
                Rectangle()
                    .stroke(.black.opacity(0.6), lineWidth: 2)
                    .overlay {
                        Rectangle().stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 1, dash: [5, 4], dashPhase: phase))
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            ForEach(0..<4) { corner in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: corner % 2 == 0 ? rect.minX : rect.maxX,
                              y: corner < 2 ? rect.minY : rect.maxY)
            }
        }
    }
}

private struct RegionOverlay: View {
    let region: StudioRegion
    let snapshotDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { StudioStyle.regionColors[region.colorIndex % StudioStyle.regionColors.count] }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || snapshotDate != nil)) { timeline in
            let frame = StudioSelectionFrame(elapsed: (snapshotDate ?? timeline.date).timeIntervalSince(region.selectedAt),
                                             reduceMotion: reduceMotion)
            GeometryReader { geometry in
                let box = region.segment.box.rect(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    if let mask = region.mask {
                        color.opacity(frame.tint)
                            .mask { Image(nsImage: mask).resizable().interpolation(.high).luminanceToAlpha() }
                        if !reduceMotion, frame.shimmer < 1.3 {
                            LinearGradient(colors: [.clear, color.opacity(0.32), .white.opacity(0.35), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.4, height: geometry.size.height)
                                .offset(x: frame.shimmer * geometry.size.width)
                                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                                .mask { Image(nsImage: mask).resizable().interpolation(.high).luminanceToAlpha() }
                        }
                    }
                    Rectangle().trim(from: 0, to: frame.drawn)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                    Text(region.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                        .frame(maxWidth: max(1, box.width - 10), alignment: .leading)
                        .offset(x: box.minX + 5, y: max(4, box.minY + 5))
                        .opacity(frame.drawn)
                }
                .clipped()
            }
        }
        .accessibilityLabel("Selected region: \(region.name)")
    }
}

/// Samples the selection reveal at a time, including when a window is offscreen.
struct StudioSelectionFrame {
    let drawn: Double
    let tint: Double
    let shimmer: Double

    init(elapsed: TimeInterval, reduceMotion: Bool) {
        func eased(_ value: Double) -> Double {
            let value = min(1, max(0, value))
            return value * value * (3 - 2 * value)
        }
        drawn = reduceMotion ? 1 : eased(elapsed / 0.55)
        tint = reduceMotion ? 0.12 : 0.28 * eased((elapsed - 0.25) / 0.55) - 0.18 * eased((elapsed - 1.75) / 0.65)
        shimmer = reduceMotion ? 1.3 : -0.6 + 1.9 * eased((elapsed - 0.45) / 1.25)
    }
}

/// Converts photo gestures to bounded coordinates without depending on zoom or display scale.
private struct AreaInteraction {
    enum Mode { case draw, move, corner(Int) }
    let start: CGPoint
    let original: NormalizedRect
    let mode: Mode

    init(start: CGPoint, area: NormalizedRect?, size: CGSize) {
        self.start = CGPoint(x: start.x / size.width, y: start.y / size.height)
        original = area ?? .whole
        guard let area else { mode = .draw; return }
        let rect = area.rect(in: size)
        for corner in 0..<4 {
            let point = CGPoint(x: corner % 2 == 0 ? rect.minX : rect.maxX,
                                y: corner < 2 ? rect.minY : rect.maxY)
            if hypot(point.x - start.x, point.y - start.y) <= 13 {
                mode = .corner(corner)
                return
            }
        }
        mode = rect.contains(start) ? .move : .draw
    }

    func rect(at location: CGPoint, size: CGSize) -> NormalizedRect {
        let point = CGPoint(x: min(1, max(0, location.x / size.width)),
                            y: min(1, max(0, location.y / size.height)))
        switch mode {
        case .draw:
            return between(start, point)
        case .move:
            return NormalizedRect(x: min(1 - original.width, max(0, original.x + point.x - start.x)),
                                  y: min(1 - original.height, max(0, original.y + point.y - start.y)),
                                  width: original.width, height: original.height)
        case .corner(let corner):
            let opposite = CGPoint(x: corner % 2 == 0 ? original.x + original.width : original.x,
                                   y: corner < 2 ? original.y + original.height : original.y)
            return between(opposite, point)
        }
    }

    private func between(_ first: CGPoint, _ second: CGPoint) -> NormalizedRect {
        NormalizedRect(x: min(first.x, second.x), y: min(first.y, second.y),
                       width: abs(first.x - second.x), height: abs(first.y - second.y))
    }
}

private extension NormalizedRect {
    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

/// Holds compare only for Space presses outside text fields in this window.
struct CompareKeyboard: NSViewRepresentable {
    let model: StudioModel

    func makeNSView(context: Context) -> CompareKeyView { CompareKeyView(model: model) }
    func updateNSView(_ view: CompareKeyView, context: Context) {}
    static func dismantleNSView(_ view: CompareKeyView, coordinator: ()) { view.stop() }
}

final class CompareKeyView: NSView {
    private let model: StudioModel
    private var monitor: Any?
    private var windowObserver: (any NSObjectProtocol)?

    init(model: StudioModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.holdingCompare = false }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        monitor = nil
        windowObserver = nil
        model.holdingCompare = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.isKeyWindow == true else { return event }
        if event.type == .keyDown, event.keyCode == 53, model.area != nil {
            model.area = nil
            return nil
        }
        guard event.keyCode == 49 else { return event }
        if event.type == .keyUp, model.holdingCompare {
            model.holdingCompare = false
            return nil
        }
        guard event.type == .keyDown, model.preview != nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(window?.firstResponder is NSTextView), !(window?.firstResponder is NSTextField) else { return event }
        model.holdingCompare = true
        return nil
    }
}
