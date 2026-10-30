import SwiftUI
import LumenCore

/// Photoeditor's design tokens, so Lumen Studio and the app read as one product: black, graphite greys and white, so
/// the chrome never biases how a photo's colour reads, and the orange-red accent kept for Lumen's own actions and the
/// few marks that must catch the eye. Standard controls are tinted grey, not the accent.
enum StudioStyle {
    static let canvas = Color(hex: 0x0E0E0F)
    static let panel = Color(hex: 0x161617)
    static let raised = Color(hex: 0x1D1D1F)
    static let hover = Color(hex: 0x242426)
    static let line = Color(hex: 0x2A2A2D)
    static let textPrimary = Color(hex: 0xE8E8EA)
    static let textSecondary = Color(hex: 0x9A9AA0)
    static let textTertiary = Color(hex: 0x5E5E64)
    static let accent = Color(hex: 0xF2552A)
    static let accentSoft = Color(hex: 0xF2552A).opacity(0.16)
    static let danger = Color(hex: 0xEC4868)
    static let success = Color(hex: 0x5ED39A)
    static let tint = Color(hex: 0x8C8C92)
    static let track = Color(hex: 0x3A3A3E)
    static let regionColors: [Color] = [accent, .cyan, .mint, .pink, .yellow, .purple]

    static let radius: CGFloat = 6
    static let promptRadius: CGFloat = 14
    static let topBarHeight: CGFloat = 44
    static let bottomBarHeight: CGFloat = 36
    static let control: CGFloat = 24
    static let gutter: CGFloat = 16
    static let barSpacing: CGFloat = 8
    static let barInset: CGFloat = 14

    static let body = Font.system(size: 12)
    static let label = Font.system(size: 11)
    static let section = Font.system(size: 11, weight: .semibold)
    static let title = Font.system(size: 13, weight: .medium)
    static let value = Font.system(size: 11).monospacedDigit()
    static let caption = Font.system(size: 10)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// A bar's icon button, as Photoeditor's: a control-high square, grey, raised on hover.
struct StudioIconButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(!isEnabled ? StudioStyle.textTertiary : isActive ? StudioStyle.textPrimary : StudioStyle.textSecondary)
                .frame(width: StudioStyle.control, height: StudioStyle.control)
                .background(RoundedRectangle(cornerRadius: StudioStyle.radius)
                    .fill(isActive ? StudioStyle.hover : hovering ? StudioStyle.raised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// A small raised pill, as Photoeditor's chips and segmented buttons; selected, it is lifted and in full white.
struct StudioChip<Label: View>: View {
    var isSelected = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(StudioStyle.label.weight(.medium))
                .foregroundStyle(isSelected ? StudioStyle.textPrimary : StudioStyle.textSecondary)
                .padding(.horizontal, 10).frame(height: StudioStyle.control)
                .background(RoundedRectangle(cornerRadius: StudioStyle.radius).fill(isSelected ? StudioStyle.hover : StudioStyle.raised))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A determinate bar drawn from its value as it changes. AppKit's bar redraws a burst of updates up to a second late:
/// a finished library showed 3 of 16 filled beside "16/16".
struct StudioProgressBar: View {
    let value: Double
    let total: Double

    var body: some View {
        // The fill is cut by the track's shape, so 2% shows the track's rounded end filled, not a thin bar.
        GeometryReader { geometry in
            Capsule().fill(StudioStyle.track)
                .overlay(alignment: .leading) {
                    Rectangle().fill(StudioStyle.accent).frame(width: geometry.size.width * (total > 0 ? min(1, max(0, value / total)) : 0))
                }
                .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value)) of \(Int(total))")
    }
}

struct StudioView: View {
    @Bindable var model: StudioModel
    var activatesBackend = true
    var openFolder: (URL) -> Void = { _ in }
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioStyle.line).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        StudioCanvas(model: model)
                        if dropTarget {
                            RoundedRectangle(cornerRadius: StudioStyle.promptRadius)
                                .fill(StudioStyle.accentSoft)
                                .overlay {
                                    RoundedRectangle(cornerRadius: StudioStyle.promptRadius)
                                        .strokeBorder(StudioStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                }
                                .padding(14)
                                .allowsHitTesting(false)
                        }
                    }
                    // The prompt floats over the bottom of the canvas, as Photoeditor's does.
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            if let issue = model.issue ?? model.backends.issue { issueBanner(issue) }
                            PromptBar(model: model)
                        }
                        .frame(maxWidth: 780)
                        .padding(.horizontal, StudioStyle.gutter).padding(.bottom, 14)
                    }
                    Rectangle().fill(StudioStyle.line).frame(height: 1)
                    StudioBottomBar(model: model)
                }
                Rectangle().fill(StudioStyle.line).frame(width: 1)
                StudioSidebar(model: model)
                    .frame(width: 300)
            }
        }
        .background(StudioStyle.panel)
        .foregroundStyle(StudioStyle.textPrimary)
        .preferredColorScheme(.dark)
        .tint(StudioStyle.tint)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                openFolder(url)
                return true
            }
            guard !model.isBusy else { return false }
            model.open(url)
            return true
        } isTargeted: { dropTarget = $0 && !model.isBusy }
        .onExitCommand { model.area = nil }
        .background(CompareKeyboard(model: model).frame(width: 0, height: 0))
        .task { if activatesBackend { await model.backends.activate() } }
        .onReceive(NotificationCenter.default.publisher(for: .studioProviderChanged)) { _ in
            Task { await model.backends.refreshAvailability() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if activatesBackend { Task { await model.backends.refreshAvailability() } }
        }
        .onDisappear { if activatesBackend { Task { await model.close() } } }
    }

    /// Photoeditor's top bar: the photo's name, state and size in a pill in the middle, the bar's actions at the right.
    private var header: some View {
        ZStack {
            HStack(spacing: StudioStyle.barSpacing) {
                Text("Lumen").font(StudioStyle.title).foregroundStyle(StudioStyle.textSecondary)
                Spacer(minLength: 12)
                StudioIconButton(symbol: "folder", help: "Open Photo (⌘O)", action: model.choosePhoto)
                    .disabled(model.isBusy)
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(StudioStyle.textSecondary)
                        .frame(width: StudioStyle.control, height: StudioStyle.control)
                }
                .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
                StudioIconButton(symbol: "square.and.arrow.up", help: "Export full-size JPEG or PNG (⌘E)", action: model.chooseExport)
                    .disabled(!model.canExport)
            }
            if model.photoURL != nil {
                HStack(spacing: 8) {
                    Text(model.photoURL?.lastPathComponent ?? "").font(StudioStyle.title)
                        .lineLimit(1).truncationMode(.middle)
                    Text(model.layers.isEmpty ? "Original" : "Edited").font(StudioStyle.label).foregroundStyle(StudioStyle.textTertiary)
                    if model.photoSize.width > 0 {
                        Text("\(model.photoSize.width.formatted()) × \(model.photoSize.height.formatted())")
                            .font(StudioStyle.value).foregroundStyle(StudioStyle.textSecondary)
                    }
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: StudioStyle.radius).fill(StudioStyle.raised))
                .frame(maxWidth: 520)
            }
        }
        .padding(.leading, 84).padding(.trailing, StudioStyle.barInset)
        .frame(height: StudioStyle.topBarHeight)
        .background(StudioStyle.panel)
    }

    private func issueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(StudioStyle.danger)
            Text(message).font(StudioStyle.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            StudioIconButton(symbol: "xmark", help: "Dismiss error") { model.issue = nil; model.backends.issue = nil }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: StudioStyle.radius).fill(StudioStyle.raised))
        .overlay { RoundedRectangle(cornerRadius: StudioStyle.radius).strokeBorder(StudioStyle.danger.opacity(0.5)) }
        .accessibilityElement(children: .contain)
    }
}

/// Photoeditor's prompt bar: a raised, rounded bar over the canvas, with the model, the styles, any marked area, the
/// instruction, what the edit has cost and the orange send button.
struct PromptBar: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(spacing: StudioStyle.barSpacing) {
            backend
            // Lumen's person styles and effects, each filling in an instruction that asks for it.
            Menu {
                Section("Person styles") {
                    ForEach(PersonStyle.all, id: \.id) { style in Button(style.title) { model.prompt = style.example } }
                }
                Section("Effects") {
                    ForEach(StyleEffect.all, id: \.id) { effect in Button(effect.title) { model.prompt = effect.example } }
                }
            } label: {
                Image(systemName: "theatermasks").font(.system(size: 13)).foregroundStyle(StudioStyle.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isRunning)
            .accessibilityLabel("Styles")
            .help("Restyle a person, or grade the photo")
            if model.area != nil {
                StudioChip(isSelected: true, action: { model.area = nil }) {
                    HStack(spacing: 5) {
                        Image(systemName: "viewfinder")
                        Text("Area")
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    }
                }
                .help("Lumen looks only here. Clear the area (Esc)")
                .accessibilityLabel("Clear area")
            }
            TextField(model.voice.isRecording ? "Listening…" : "Describe what you want to change", text: $model.prompt)
                .textFieldStyle(.plain)
                .font(StudioStyle.title)
                .disabled(model.isRunning || model.voice.isRecording)
                .onSubmit(model.run)
                .accessibilityLabel("Edit instruction")
            StudioMicButton(voice: model.voice, disabled: model.isRunning, heard: model.hear) { model.issue = $0 }
            if model.modelCalls > 0 {
                Text("\(model.modelCalls) \(model.modelCalls == 1 ? "call" : "calls") · \(studioDollars(model.totalCost))")
                    .font(StudioStyle.label).monospacedDigit().foregroundStyle(StudioStyle.textSecondary)
                    .fixedSize()
            }
            if model.isRunning {
                sendButton(symbol: "stop.fill", help: model.phase == .stopping ? "Stopping" : "Stop", enabled: model.phase != .stopping,
                           action: model.stop)
            } else if !model.voice.isRecording {
                sendButton(symbol: "arrow.up", help: "Run instruction (Return)", enabled: model.canRun && !model.voice.isTranscribing,
                           action: model.run)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: StudioStyle.promptRadius).fill(StudioStyle.raised))
        .overlay { RoundedRectangle(cornerRadius: StudioStyle.promptRadius).strokeBorder(StudioStyle.line) }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
    }

    private func sendButton(symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? Color.white : StudioStyle.textTertiary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(enabled ? StudioStyle.accent : StudioStyle.hover))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var backend: some View {
        Menu {
            ForEach(StudioScript.Backend.allCases, id: \.self) { backend in
                let availability = model.backends.availability(for: backend)
                Button { model.chooseBackend(backend) } label: {
                    if backend == model.backends.selection { Label(backend.title, systemImage: "checkmark") }
                    else { Text(backend.title) }
                }
                .disabled(!availability.isEnabled)
                .help(availability.help)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkle").foregroundStyle(StudioStyle.accent)
                Text(model.backends.selection.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(StudioStyle.label)
            .foregroundStyle(StudioStyle.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Model backend: \(model.backends.selection.title)")
        .simultaneousGesture(TapGesture().onEnded { Task { await model.backends.refreshAvailability() } })
    }
}

/// Photoeditor's bottom bar: what the edit is doing, then the canvas's own controls.
struct StudioBottomBar: View {
    @Bindable var model: StudioModel

    var body: some View {
        HStack(spacing: StudioStyle.barSpacing) {
            if model.isBusy || model.backends.isLoading { ProgressView().controlSize(.mini) }
            Text(model.status).lineLimit(1).truncationMode(.tail).help(model.status)
                .foregroundStyle(StudioStyle.textSecondary)
            Spacer(minLength: 12)
            Text(model.area == nil ? "Drag on the photo to choose an area" : "Drag to move · Corners to resize · Esc to clear")
                .foregroundStyle(StudioStyle.textTertiary).lineLimit(1)
            StudioIconButton(symbol: "minus", help: "Zoom out") { model.zoom = max(0.5, model.zoom / 1.25) }
            StudioChip(action: { model.zoom = 1 }) {
                Text(model.zoom == 1 ? "Fit" : String(format: "%.0f%%", model.zoom * 100)).monospacedDigit().frame(minWidth: 30)
            }
            .help("Fit photo to canvas. Percentages are relative to fit.")
            StudioIconButton(symbol: "plus", help: "Zoom in") { model.zoom = min(4, model.zoom * 1.25) }
            StudioChip(isSelected: model.showsOriginal, action: { model.compare.toggle() }) {
                HStack(spacing: 5) { Image(systemName: "square.on.square"); Text("Before / After") }
            }
            .help("Show the original, or hold Space while not typing")
            .accessibilityLabel("Compare")
            .accessibilityValue(model.showsOriginal ? "Original" : "Edited")
        }
        .font(StudioStyle.caption)
        .padding(.horizontal, StudioStyle.barInset)
        .frame(height: StudioStyle.bottomBarHeight)
        .background(StudioStyle.panel)
        .disabled(model.preview == nil && !model.isBusy)
    }
}

struct StudioSidebar: View {
    @Bindable var model: StudioModel

    var body: some View {
        VStack(spacing: 0) {
            // Photoeditor's panel title row, with its pill segments.
            HStack(spacing: 4) {
                Text(model.sidebar == .steps ? "Steps" : "Layers").font(.system(size: 15, weight: .semibold))
                Spacer()
                StudioChip(isSelected: model.sidebar == .steps, action: { model.sidebar = .steps }) { Text("Steps") }
                StudioChip(isSelected: model.sidebar == .layers, action: { model.sidebar = .layers }) {
                    Text("Layers · \(model.layers.count + (model.batchStraightening == nil ? 0 : 1))")
                }
            }
            .padding(.horizontal, StudioStyle.gutter).frame(height: StudioStyle.topBarHeight + 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar")
            if model.sidebar == .steps { timeline }
            else { layerList }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "square.3.layers.3d")
                Text("Your original stays untouched")
            }
            .font(StudioStyle.caption).foregroundStyle(StudioStyle.textTertiary)
            .frame(maxWidth: .infinity).frame(height: StudioStyle.bottomBarHeight)
            .overlay(alignment: .top) { Rectangle().fill(StudioStyle.line).frame(height: 1) }
        }
        .background(StudioStyle.panel)
    }

    private var timeline: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !model.planSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkle").foregroundStyle(StudioStyle.accent)
                                Text("Plan")
                            }
                            .font(StudioStyle.section).foregroundStyle(StudioStyle.textSecondary)
                            Text(model.planSummary).font(StudioStyle.title).lineSpacing(4)
                                .lineLimit(4).help(model.planSummary)
                                .textSelection(.enabled)
                        }
                        .padding(.bottom, 4)
                    }
                    if model.steps.isEmpty {
                        sidebarEmpty("A clear view of every step", detail: "The plan, selections, changes, and checks appear here as your edit runs.", symbol: "list.bullet.indent")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.steps) { step in
                                TimelineRow(entry: step, isLast: step.id == model.steps.last?.id)
                                    .id(step.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, StudioStyle.gutter).padding(.top, 4).padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.timelineFocus) {
                if let id = model.timelineFocus {
                    withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var layerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.layers.isEmpty && model.batchStraightening == nil {
                    sidebarEmpty("Built one layer at a time", detail: "Applied edits appear here. Adjust their opacity, hide them, or undo a step.", symbol: "square.3.layers.3d")
                } else {
                    HStack {
                        let count = model.layers.count + (model.batchStraightening == nil ? 0 : 1)
                        Text("\(count) \(count == 1 ? "layer" : "layers")").font(StudioStyle.section)
                            .foregroundStyle(StudioStyle.textSecondary)
                        Spacer()
                        StudioIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: model.undo)
                            .disabled(!model.canUndo)
                        StudioIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: model.redo)
                            .disabled(!model.canRedo)
                    }
                    ForEach(model.layers.reversed()) { layer in
                        LayerRow(model: model, layer: layer)
                    }
                    if let angle = model.batchStraightening {
                        let on = model.straighteningAngle != 0
                        HStack(spacing: 8) {
                            StudioIconButton(symbol: on ? "circle.inset.filled" : "circle", help: on ? "Turn off" : "Turn on",
                                             isActive: on, action: model.toggleStraightening)
                                .accessibilityLabel("Straighten")
                            Text("Straighten · \(angle.formatted())°").font(StudioStyle.body.weight(.medium))
                                .foregroundStyle(on ? StudioStyle.textPrimary : StudioStyle.textTertiary)
                            Spacer(minLength: 0)
                        }
                        .disabled(model.isBusy)
                        .padding(12).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.radius))
                        .overlay { RoundedRectangle(cornerRadius: StudioStyle.radius).strokeBorder(StudioStyle.line) }
                    }
                }
                if model.photoURL != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "photo").foregroundStyle(StudioStyle.textSecondary)
                        Text("Original").font(StudioStyle.body.weight(.medium))
                        Spacer()
                        Image(systemName: "lock").font(StudioStyle.caption).foregroundStyle(StudioStyle.textTertiary)
                    }
                    .padding(12)
                    .background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: StudioStyle.radius))
                    .overlay { RoundedRectangle(cornerRadius: StudioStyle.radius).strokeBorder(StudioStyle.line) }
                }
            }
            .padding(.horizontal, StudioStyle.gutter).padding(.bottom, 24)
        }
    }

    private func sidebarEmpty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light))
                .foregroundStyle(StudioStyle.textTertiary).padding(.bottom, 6)
            Text(title).font(StudioStyle.title)
            Text(detail).font(StudioStyle.body).foregroundStyle(StudioStyle.textSecondary).lineSpacing(5)
        }
        .padding(.top, 36).padding(.bottom, 30)
    }
}

struct TimelineRow: View {
    let entry: StudioStep
    let isLast: Bool
    @State private var showsTraces = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 6) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(entry.status == .running ? StudioStyle.accent : StudioStyle.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.radius))
                if !isLast { Rectangle().fill(StudioStyle.line).frame(width: 1).frame(minHeight: 24) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.title).font(StudioStyle.body.weight(.medium)).lineSpacing(3)
                    .lineLimit(2).truncationMode(.tail).help(entry.title)
                HStack(spacing: 5) {
                    if entry.status == .running { ProgressView().controlSize(.mini) }
                    else if entry.status == .done { Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold)) }
                    Text(entry.status.label)
                }
                .font(StudioStyle.caption).foregroundStyle(statusColor)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail).font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary).lineSpacing(4)
                        .lineLimit(2).truncationMode(.tail).help(detail)
                        .textSelection(.enabled)
                }
                if let message = entry.status.message {
                    Text(message).font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary).lineSpacing(3)
                        .lineLimit(3).help(message)
                        .textSelection(.enabled)
                }
                if !entry.traces.isEmpty {
                    DisclosureGroup("Details · \(entry.traces.count)", isExpanded: $showsTraces) {
                        traces
                    }
                    .font(StudioStyle.caption)
                    .foregroundStyle(StudioStyle.textSecondary)
                }
            }
            .padding(.top, 4).padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    private var traces: some View {
        ForEach(Array(entry.traces.enumerated()), id: \.offset) { _, trace in
            VStack(alignment: .leading, spacing: 4) {
                if let model = trace.studioModelName {
                    Text("\(model) · \(trace.duration.formatted(.number.precision(.fractionLength(1)))) s\(trace.cost.map { " · " + studioDollars($0) } ?? "")")
                        .font(StudioStyle.caption.monospacedDigit()).foregroundStyle(StudioStyle.textTertiary)
                }
                if !trace.detail.isEmpty, trace.detail != entry.detail, trace.detail != entry.status.message {
                    Text(trace.detail).font(StudioStyle.caption).foregroundStyle(StudioStyle.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .running: StudioStyle.accent
        case .done: StudioStyle.success
        case .failed: StudioStyle.danger
        case .waiting, .skipped: StudioStyle.textTertiary
        }
    }
}

private struct LayerRow: View {
    let model: StudioModel
    let layer: Layer

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // Photoeditor's mask and layer rows: a filled circle while it shows, an empty one while it's off.
            HStack(alignment: .top, spacing: 8) {
                StudioIconButton(symbol: layer.isEnabled ? "circle.inset.filled" : "circle",
                                 help: layer.isEnabled ? "Turn off" : "Turn on", isActive: layer.isEnabled) {
                    model.toggleLayer(layer.id)
                }
                .accessibilityLabel(layer.label)
                .accessibilityValue(layer.isEnabled ? "On" : "Off")
                Text(layer.label).font(StudioStyle.body.weight(.medium))
                    .foregroundStyle(layer.isEnabled ? StudioStyle.textPrimary : StudioStyle.textTertiary)
                    .lineLimit(2).truncationMode(.tail).help(layer.label)
                    .frame(maxWidth: .infinity, minHeight: StudioStyle.control, alignment: .leading)
            }
            HStack(spacing: 10) {
                Text("Opacity").font(StudioStyle.caption).foregroundStyle(StudioStyle.textSecondary)
                Slider(value: Binding(get: { layer.opacity }, set: { model.setOpacity($0, for: layer.id) }),
                       in: 0...1, onEditingChanged: { if !$0 { model.commitLayerChanges() } })
                    .controlSize(.mini)
                    .accessibilityLabel("Opacity for \(layer.label)")
                Text(layer.opacity.formatted(.percent.precision(.fractionLength(0))))
                    .font(StudioStyle.value).foregroundStyle(StudioStyle.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(12)
        .background(layer.isEnabled ? StudioStyle.raised : StudioStyle.panel, in: RoundedRectangle(cornerRadius: StudioStyle.radius))
        .overlay { RoundedRectangle(cornerRadius: StudioStyle.radius).strokeBorder(StudioStyle.line) }
        .disabled(model.isBusy)
    }
}

func studioDollars(_ cost: Double, estimated: Bool = false) -> String {
    String(format: estimated ? "$%.2f" : "$%.4f", locale: Locale(identifier: "en_US_POSIX"), cost)
}
