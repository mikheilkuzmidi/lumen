import SwiftUI
import ImageIO
import LumenCore
import UniformTypeIdentifiers

struct StudioLibraryView: View {
    @Bindable var model: StudioLibraryModel
    var activatesBackend = true
    var openFolder: (URL) -> Void = { _ in }
    var openPhoto: (PhotoID) -> Void = { _ in }
    @State private var thumbnails = LibraryThumbnails()
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioStyle.line).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let question = model.question { questionCard(question) }
                    else if let decision = model.recentDecision { decisionCard(decision) }
                    if let plan = model.plan, let calls = model.estimatedModelCalls { planPanel(plan, calls: calls) }
                    grid
                    // Not animated: a capture of a finished library showed the bar still catching up.
                    ProgressView(value: Double(model.done), total: Double(max(1, model.total)))
                        .tint(StudioStyle.accent).progressViewStyle(.linear)
                        .animation(nil, value: model.done)
                    Rectangle().fill(StudioStyle.line).frame(height: 1)
                    HStack(spacing: StudioStyle.barSpacing) {
                        if model.isRunning { ProgressView().controlSize(.mini) }
                        Text(model.backends.isLoading ? model.backends.status ?? model.status : model.status).lineLimit(1)
                        Spacer()
                        Text("\(model.done)/\(model.total) · \(model.modelCalls) model calls · \(studioDollars(model.totalCost))")
                            .monospacedDigit()
                    }
                    .font(StudioStyle.caption).foregroundStyle(StudioStyle.textSecondary)
                    .padding(.horizontal, StudioStyle.barInset).frame(height: StudioStyle.bottomBarHeight)
                }
                Rectangle().fill(StudioStyle.line).frame(width: 1)
                sidebar.frame(width: 300)
            }
        }
        .background(StudioStyle.panel)
        .foregroundStyle(StudioStyle.textPrimary)
        .preferredColorScheme(.dark).tint(StudioStyle.tint)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: StudioStyle.promptRadius).strokeBorder(StudioStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            openFolder(url)
            return true
        } isTargeted: { dropTarget = $0 }
        .task { if activatesBackend { await model.backends.activate() } }
        .onReceive(NotificationCenter.default.publisher(for: .studioProviderChanged)) { _ in
            Task { await model.backends.refreshAvailability() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if activatesBackend { Task { await model.backends.refreshAvailability() } }
        }
    }

    /// Photoeditor's top bar: the library's name and size in a pill in the middle, its actions at the right.
    private var header: some View {
        ZStack {
            HStack(spacing: StudioStyle.barSpacing) {
                Text("Lumen").font(StudioStyle.title).foregroundStyle(StudioStyle.textSecondary)
                Spacer(minLength: 12)
                StudioChip(isSelected: model.compare, action: { model.compare.toggle() }) {
                    HStack(spacing: 5) { Image(systemName: "square.on.square"); Text("Before / After") }
                }
                .help("Show the original photos").accessibilityLabel("Before")
                StudioIconButton(symbol: "folder", help: "Reveal the output folder", action: model.revealOutput)
                    .disabled(model.output == nil)
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(StudioStyle.textSecondary)
                        .frame(width: StudioStyle.control, height: StudioStyle.control)
                }
                .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            HStack(spacing: 8) {
                Text(model.folder?.lastPathComponent ?? "Library").font(StudioStyle.title).lineLimit(1)
                Text("\(model.photos.count) photos").font(StudioStyle.value).foregroundStyle(StudioStyle.textSecondary)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: StudioStyle.radius).fill(StudioStyle.raised))
        }
        .padding(.leading, 84).padding(.trailing, StudioStyle.barInset)
        .frame(height: StudioStyle.topBarHeight)
    }

    private var grid: some View {
        let highlighted = model.highlightedPhotos
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 240), spacing: 16)], spacing: 18) {
                ForEach(model.photos, id: \.self) { photo in
                    LibraryPhotoCell(model: model, photo: photo, thumbnails: thumbnails,
                                     highlighted: highlighted.contains(photo)) { openPhoto(photo) }
                }
            }
            .padding(24)
        }
        .background(StudioStyle.canvas)
        .overlay {
            if model.isOpening { ProgressView("Opening library…") }
            else if model.photos.isEmpty { Text("No photos in this folder").font(StudioStyle.title).foregroundStyle(StudioStyle.textSecondary) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Edit the library").font(.system(size: 15, weight: .semibold))
                    TextField("Describe a change, or run the base pass", text: $model.instruction, axis: .vertical)
                        .textFieldStyle(.plain).font(StudioStyle.title).lineLimit(3...6)
                        .padding(12).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.promptRadius))
                        .overlay { RoundedRectangle(cornerRadius: StudioStyle.promptRadius).strokeBorder(StudioStyle.line) }
                    Picker("Mode", selection: $model.mode) {
                        Text("Autonomous").tag(BatchMode.autonomous)
                        Text("Ask me").tag(BatchMode.askWhenUnsure)
                        Text("Plan first").tag(BatchMode.planFirst)
                    }
                    Toggle("Auto", isOn: $model.auto)
                    Picker("Straighten", selection: $model.straighten) {
                        ForEach(LibraryStraighten.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Toggle("Flag misfires", isOn: $model.flagMisfires)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Quality threshold"); Spacer(); Text(model.qualityThreshold.formatted(.number.precision(.fractionLength(2)))).monospacedDigit() }
                        Slider(value: $model.qualityThreshold, in: 0...1).controlSize(.mini)
                            .accessibilityLabel("Quality threshold")
                        Text("Photos below this get a closer look.").font(StudioStyle.caption).foregroundStyle(StudioStyle.textTertiary)
                    }
                    backend
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Results").font(StudioStyle.section).foregroundStyle(StudioStyle.textSecondary)
                        Text(model.output?.path ?? "").font(StudioStyle.caption).foregroundStyle(StudioStyle.textSecondary).lineLimit(2).help(model.output?.path ?? "")
                        Button("Change folder…", action: model.chooseOutput)
                    }
                }
                .font(StudioStyle.body).toggleStyle(.switch).controlSize(.small)
                .disabled(model.isRunning || !model.canRun)
                .padding(StudioStyle.gutter)
            }
            .frame(maxHeight: 480)
            HStack(spacing: StudioStyle.barSpacing) {
                Button(action: model.run) {
                    Label("Run", systemImage: "play.fill").font(StudioStyle.body.weight(.semibold))
                        .foregroundStyle(model.canRun ? Color.white : StudioStyle.textTertiary)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: StudioStyle.radius).fill(model.canRun ? StudioStyle.accent : StudioStyle.hover))
                }
                .buttonStyle(.plain).disabled(!model.canRun)
                StudioChip(action: model.stop) { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!model.isRunning || model.isStopping)
            }
            .padding(.horizontal, StudioStyle.gutter).padding(.bottom, StudioStyle.gutter)
            if let issue = model.issue ?? model.backends.issue {
                Text(issue).font(StudioStyle.label).foregroundStyle(StudioStyle.danger).textSelection(.enabled).padding(StudioStyle.gutter)
            }
            Rectangle().fill(StudioStyle.line).frame(height: 1)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.events) { event in
                            TimelineRow(entry: event, isLast: event.id == model.events.last?.id).id(event.id)
                        }
                        if !model.decisions.isEmpty {
                            DisclosureGroup("Decisions · \(model.decisions.count)") {
                                ForEach(Array(model.decisions.enumerated()), id: \.offset) { _, answer in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(answer.question.question).foregroundStyle(StudioStyle.textSecondary)
                                        Text("Decided: \(answer.answer)").foregroundStyle(StudioStyle.textPrimary)
                                    }.font(StudioStyle.label).padding(.vertical, 8)
                                }
                            }.font(StudioStyle.label)
                        }
                    }.padding(StudioStyle.gutter)
                }
                .onChange(of: model.events.last?.id) {
                    if let id = model.events.last?.id { scroll.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var backend: some View {
        Menu {
            ForEach(StudioScript.Backend.allCases, id: \.self) { backend in
                let availability = model.backends.availability(for: backend)
                Button { model.backends.choose(backend) } label: {
                    if model.backends.selection == backend { Label(backend.title, systemImage: "checkmark") }
                    else { Text(backend.title) }
                }
                .disabled(!availability.isEnabled).help(availability.help)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkle").foregroundStyle(StudioStyle.accent)
                Text(model.backends.selection.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Planner")
        .simultaneousGesture(TapGesture().onEnded { Task { await model.backends.refreshAvailability() } })
    }

    private func questionCard(_ question: BatchQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.question).font(StudioStyle.title)
            ViewThatFits(in: .horizontal) {
                HStack { options(question) }
                VStack(alignment: .leading) { options(question) }
            }
        }
        .padding(StudioStyle.gutter).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioStyle.line).frame(height: 1) }
    }

    private func options(_ question: BatchQuestion) -> some View {
        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
            StudioChip(isSelected: index == question.recommended, action: { Task { await model.answer(option) } }) {
                HStack(spacing: 6) {
                    Text(option).font(StudioStyle.body)
                    if index == question.recommended { Text("Recommended").font(StudioStyle.caption).foregroundStyle(StudioStyle.accent) }
                }
            }
            .disabled(model.isStopping)
        }
    }

    private func decisionCard(_ answer: BatchAnswer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Decided: \(answer.answer)").font(StudioStyle.title)
            Text(answer.question.question).font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
        }
        .padding(StudioStyle.gutter).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioStyle.line).frame(height: 1) }
    }

    private func planPanel(_ plan: BatchPlan, calls: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.summary).font(StudioStyle.title)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.groups) { group in
                        Button { model.selectedGroup = group.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(group.title) · \(group.photos.count) \(group.photos.count == 1 ? "photo" : "photos")").font(StudioStyle.body.weight(.medium))
                                Text(group.instruction ?? "Base pass").font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(model.selectedGroup == group.id ? StudioStyle.hover : StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.radius))
                            .overlay { RoundedRectangle(cornerRadius: StudioStyle.radius).strokeBorder(model.selectedGroup == group.id ? StudioStyle.accent : StudioStyle.line) }
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 180)
            HStack {
                Text("About \(calls) more model calls" + (plan.estimatedCost.map { ", about " + studioDollars($0, estimated: true) + " USD" } ?? "")).font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
                Spacer()
                StudioChip(action: model.stop) { Text("Cancel") }
                Button { Task { await model.approve() } } label: {
                    Text("Go ahead").font(StudioStyle.body.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: StudioStyle.control)
                        .background(RoundedRectangle(cornerRadius: StudioStyle.radius).fill(StudioStyle.accent))
                }
                .buttonStyle(.plain)
            }.disabled(model.isStopping)
        }
        .padding(StudioStyle.gutter)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioStyle.line).frame(height: 1) }
    }
}

private struct LibraryPhotoCell: View {
    let model: StudioLibraryModel
    let photo: PhotoID
    let thumbnails: LibraryThumbnails
    let highlighted: Bool
    let open: () -> Void
    @State private var image: NSImage?
    @State private var issue: String?

    private var revision: String { "\(model.folder?.path ?? ""):\(model.compare):\(model.states[photo]?.revision ?? 0)" }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: StudioStyle.radius).fill(StudioStyle.raised)
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: issue == nil ? "photo" : "exclamationmark.triangle").foregroundStyle(StudioStyle.textTertiary) }
                }
                .frame(height: 140).clipShape(RoundedRectangle(cornerRadius: StudioStyle.radius))
                .overlay { RoundedRectangle(cornerRadius: StudioStyle.radius).strokeBorder(highlighted ? StudioStyle.accent : StudioStyle.line, lineWidth: highlighted ? 2 : 1) }
                Text(photo.rawValue).font(StudioStyle.label.weight(.medium)).lineLimit(1).truncationMode(.middle)
                badges.frame(minHeight: 72, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.rawValue), \(LibraryBadge.allCases.filter { model.states[photo]?.badges.contains($0) == true }.map(\.rawValue).joined(separator: ", "))")
        .accessibilityHint(model.isRunning ? "Stop the library to inspect layers" : "Open this photo and its layers")
        .help(model.states[photo]?.reason ?? issue ?? photo.rawValue)
        .task(id: revision) {
            guard let folder = model.folder else { return }
            do {
                let original = model.compare || (model.states[photo]?.revision ?? 0) == 0
                let loaded = try await thumbnails.image(key: "\(folder.path)/\(photo.rawValue):\(original ? "original" : revision)") {
                    if original { return try await LibraryThumbnailReader.shared.read(folder.appendingPathComponent(photo.rawValue)) }
                    return try await model.thumbnail(photo)
                }
                try Task.checkCancellation()
                image = loaded; issue = nil
            } catch is CancellationError {} catch { issue = error.localizedDescription }
        }
    }

    private var badges: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(LibraryBadge.allCases.filter { model.states[photo]?.badges.contains($0) == true }, id: \.self) { badge in
                Text(badge.rawValue).font(.system(size: 9, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundStyle(badge == .failed || badge == .attention || badge == .misfire ? StudioStyle.danger : StudioStyle.success)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// Bounds decoded grid images while cells request thumbnails only as they appear.
@MainActor
final class LibraryThumbnails {
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.totalCostLimit = 64 * 1024 * 1024 }

    func image(key: String, load: () async throws -> EncodedImage) async throws -> NSImage {
        if let image = cache.object(forKey: key as NSString) { return image }
        try Task.checkCancellation()
        let encoded = try await load()
        try Task.checkCancellation()
        guard let image = NSImage(data: encoded.data) else { throw StudioPhotoError.unreadablePreview }
        cache.setObject(image, forKey: key as NSString, cost: encoded.size.width * encoded.size.height * 4)
        return image
    }
}

private actor LibraryThumbnailReader {
    static let shared = LibraryThumbnailReader()
    func read(_ url: URL) throws -> EncodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360,
              ] as CFDictionary) else { throw StudioPhotoError.unreadablePreview }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw StudioPhotoError.unreadablePreview
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioPhotoError.unreadablePreview }
        return EncodedImage(data: data as Data, format: .jpeg, size: PixelSize(width: image.width, height: image.height))
    }
}
