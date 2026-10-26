import SwiftUI
import LumenCore

enum StudioStyle {
    static let accent = Color(red: 0.80, green: 0.91, blue: 0.66)
    static let canvas = Color(red: 0.055, green: 0.060, blue: 0.067)
    static let panel = Color(red: 0.085, green: 0.092, blue: 0.100)
    static let line = Color.white.opacity(0.08)
    static let regionColors: [Color] = [accent, .cyan, .orange, .pink, .mint, .yellow]
}

struct StudioView: View {
    @Bindable var model: StudioModel
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
                            RoundedRectangle(cornerRadius: 16)
                                .fill(StudioStyle.accent.opacity(0.08))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(StudioStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                }
                                .padding(14)
                                .allowsHitTesting(false)
                        }
                    }
                    if let issue = model.issue { issueBanner(issue) }
                    PromptBar(model: model)
                }
                Rectangle().fill(StudioStyle.line).frame(width: 1)
                StudioSidebar(model: model)
                    .frame(width: 300)
            }
        }
        .background(StudioStyle.panel)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy, let url = urls.first, url.isFileURL else { return false }
            model.open(url)
            return true
        } isTargeted: { dropTarget = $0 && !model.isBusy }
        .onExitCommand { model.area = nil }
        .background(CompareKeyboard(model: model).frame(width: 0, height: 0))
    }

    private var header: some View {
        HStack(spacing: 18) {
            Text("LUMEN")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(3.5)
                .foregroundStyle(StudioStyle.accent)
            Rectangle().fill(StudioStyle.line).frame(width: 1, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.photoURL?.lastPathComponent ?? "Studio")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if model.photoSize.width > 0 {
                    Text("\(model.photoSize.width) × \(model.photoSize.height)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button(action: model.choosePhoto) { Image(systemName: "folder") }
                .help("Open Photo (⌘O)")
                .accessibilityLabel("Open photo")
                .disabled(model.isBusy)
            SettingsLink { Image(systemName: "gearshape") }
                .help("Settings")
                .accessibilityLabel("Settings")
            Button(action: model.chooseExport) { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(!model.canExport)
                .help("Export full-size JPEG or PNG (⌘E)")
        }
        .buttonStyle(.borderless)
        .padding(.leading, 88)
        .padding(.trailing, 22)
        .frame(height: 60)
    }

    private func issueBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.issue = nil } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }
        .padding(14)
        .background(Color.orange.opacity(0.07))
        .overlay(alignment: .top) { Rectangle().fill(StudioStyle.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

struct PromptBar: View {
    @Bindable var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                backend
                Spacer()
                if model.area != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                        Text("Lumen looks here")
                        Button { model.area = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear area")
                        .help("Clear area (Esc)")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioStyle.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(StudioStyle.accent.opacity(0.08), in: Capsule())
                }
            }
            HStack(spacing: 14) {
                Image(systemName: "sparkle").foregroundStyle(StudioStyle.accent)
                    .font(.system(size: 18))
                TextField("Describe what you want to change", text: $model.prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .disabled(model.isRunning)
                    .onSubmit(model.run)
                    .accessibilityLabel("Edit instruction")
                if model.isRunning {
                    Button(action: model.stop) {
                        Label(model.phase == .stopping ? "Stopping" : "Stop", systemImage: "stop.fill")
                    }
                    .disabled(model.phase == .stopping)
                    .buttonStyle(.bordered)
                } else {
                    Button(action: model.run) {
                        HStack(spacing: 9) {
                            Text("Run").fontWeight(.semibold)
                            Image(systemName: "return").font(.caption)
                        }
                        .padding(.horizontal, 5).padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .foregroundStyle(StudioStyle.canvas)
                    .disabled(!model.canRun)
                    .help("Run instruction (Return)")
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(StudioStyle.line) }
            HStack(spacing: 7) {
                if model.isBusy { ProgressView().controlSize(.mini) }
                else { Circle().fill(StudioStyle.accent.opacity(0.7)).frame(width: 4, height: 4) }
                Text(model.status).lineLimit(2)
                Spacer(minLength: 0)
                Text("Every edit, a layer").foregroundStyle(.tertiary)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 18)
        .background(StudioStyle.panel)
        .overlay(alignment: .top) { Rectangle().fill(StudioStyle.line).frame(height: 1) }
    }

    private var backend: some View {
        Menu {
            Button {} label: { Label("Meta (Muse Spark)", systemImage: "checkmark") }
            Divider()
            Button("Muse Glimmer on this Mac · Local runtime unavailable") {}.disabled(true)
            Button("Muse Spark Open · Hosting provider not configured") {}.disabled(true)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(StudioStyle.accent).frame(width: 5, height: 5)
                Text("Meta (Muse Spark)")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Model backend: Meta, Muse Spark")
    }
}

struct StudioSidebar: View {
    let model: StudioModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $tab) {
                Text("Steps").tag(0)
                Text("Layers · \(model.layers.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(18)
            if tab == 0 { timeline }
            else { layerList }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "square.3.layers.3d")
                Text("Your original stays untouched")
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity).padding(16)
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
                            Text("THE PLAN").font(.system(size: 9, weight: .semibold)).tracking(1.8)
                                .foregroundStyle(StudioStyle.accent)
                            Text(model.planSummary).font(.system(size: 13)).lineSpacing(4)
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
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
            }
            .onChange(of: model.status) {
                if let step = model.steps.first(where: { $0.status == .running }) ?? model.steps.last {
                    scroll.scrollTo(step.id, anchor: .center)
                }
            }
        }
    }

    private var layerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.layers.isEmpty {
                    sidebarEmpty("Built one layer at a time", detail: "Applied edits appear here. Adjust their opacity, hide them, or undo a step.", symbol: "square.3.layers.3d")
                } else {
                    HStack {
                        Text("\(model.layers.count) layers").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                            .disabled(!model.canUndo).help("Undo (⌘Z)")
                            .accessibilityLabel("Undo layer change")
                        Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                            .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
                            .accessibilityLabel("Redo layer change")
                    }
                    .buttonStyle(.borderless)
                    ForEach(model.layers.reversed()) { layer in
                        LayerRow(model: model, layer: layer)
                    }
                }
                if model.photoURL != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                        Text("Original").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "lock").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 24)
        }
    }

    private func sidebarEmpty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 23, weight: .light))
                .foregroundStyle(.tertiary).padding(.bottom, 6)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
        }
        .padding(.top, 36).padding(.bottom, 30)
    }
}

private struct TimelineRow: View {
    let entry: StudioStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 6) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 28, height: 28)
                    .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                if !isLast { Rectangle().fill(StudioStyle.line).frame(width: 1).frame(minHeight: 24) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.title).font(.system(size: 12, weight: .medium)).lineSpacing(3)
                HStack(spacing: 5) {
                    if entry.status == .running { ProgressView().controlSize(.mini) }
                    else if entry.status == .done { Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold)) }
                    Text(entry.status.label)
                }
                .font(.system(size: 10)).foregroundStyle(statusColor)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        .textSelection(.enabled)
                }
                if let message = entry.status.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                        .textSelection(.enabled)
                }
                ForEach(Array(entry.traces.enumerated()), id: \.offset) { _, trace in
                    VStack(alignment: .leading, spacing: 4) {
                        if let model = trace.model {
                            Text("\(model) · \(trace.duration.formatted(.number.precision(.fractionLength(1)))) s")
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        if !trace.detail.isEmpty, trace.detail != entry.detail, trace.detail != entry.status.message {
                            Text(trace.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 5).padding(.bottom, 25)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch entry.status {
        case .running, .done: StudioStyle.accent
        case .failed: .orange
        case .waiting, .skipped: .secondary
        }
    }
}

private struct LayerRow: View {
    let model: StudioModel
    let layer: Layer

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Toggle(isOn: Binding(get: { layer.isEnabled }, set: { _ in model.toggleLayer(layer.id) })) {
                Text(layer.label).font(.system(size: 12, weight: .medium)).lineLimit(3)
            }
            .toggleStyle(.switch).controlSize(.mini)
            HStack(spacing: 10) {
                Text("Opacity").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { layer.opacity }, set: { model.setOpacity($0, for: layer.id) }),
                       in: 0...1, onEditingChanged: { if !$0 { model.commitLayerChanges() } })
                    .controlSize(.mini)
                    .accessibilityLabel("Opacity for \(layer.label)")
                Text(layer.opacity.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(14)
        .background(Color.white.opacity(layer.isEnabled ? 0.045 : 0.02), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.line) }
        .disabled(model.isBusy)
    }
}
