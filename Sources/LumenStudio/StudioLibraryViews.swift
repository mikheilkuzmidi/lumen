import SwiftUI
import ImageIO
import LumenCore
import LumenUI
import UniformTypeIdentifiers

struct StudioLibraryView: View {
    @Bindable var model: StudioLibraryModel
    var activatesBackend = true
    var openFolder: (URL) -> Void = { _ in }
    var openPhoto: (PhotoID) -> Void = { _ in }
    @State private var thumbnails = LibraryThumbnails()
    @State private var dropTarget = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var assistantStyle: AssistantStyle {
        AssistantStyle(panel: StudioStyle.panel, raised: StudioStyle.raised, line: StudioStyle.line,
                       primary: StudioStyle.textPrimary, secondary: StudioStyle.textSecondary,
                       accent: StudioStyle.accent, danger: StudioStyle.danger, radius: StudioStyle.promptRadius)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioStyle.line).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    grid
                    assistant.padding(.horizontal, 20).padding(.vertical, 14)
                        .frame(maxWidth: 820)
                    footer
                }
                .frame(maxWidth: .infinity)
                if model.reviewShown {
                    Rectangle().fill(StudioStyle.line).frame(width: 1)
                    sidebar.frame(width: 332).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(StudioStyle.panel).foregroundStyle(StudioStyle.textPrimary)
        .preferredColorScheme(.dark).tint(StudioStyle.tint)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.reviewShown)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: StudioStyle.promptRadius)
                    .strokeBorder(StudioStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
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

    private var header: some View {
        HStack(spacing: 12) {
            StudioWindowTitle()
            Spacer(minLength: 12)
            Text(model.folder?.lastPathComponent ?? "Library").font(StudioStyle.title).lineLimit(1)
            Text("\(model.photos.count) photos").font(StudioStyle.value).foregroundStyle(StudioStyle.textSecondary)
            Spacer(minLength: 12)
            StudioChip(isSelected: model.compare, action: { model.compare.toggle() }) {
                Label("Before / After", systemImage: "square.on.square")
            }.accessibilityLabel("Before")
            StudioIconButton(symbol: "folder", help: "Reveal the output folder", action: model.revealOutput)
                .disabled(model.output == nil)
            SettingsLink { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                .buttonStyle(.plain).accessibilityLabel("Settings")
        }
        .padding(.horizontal, StudioStyle.barInset).frame(height: StudioStyle.topBarHeight)
    }

    private var grid: some View {
        let highlighted = model.highlightedPhotos
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 240), spacing: 6)], spacing: 6) {
                ForEach(model.photos, id: \.self) { photo in
                    LibraryPhotoCell(model: model, photo: photo, thumbnails: thumbnails,
                                     highlighted: highlighted.contains(photo)) { openPhoto(photo) }
                }
            }.padding(14)
        }
        .background(StudioStyle.canvas)
        .accessibilityIdentifier("libraryGrid")
        .overlay {
            if model.isOpening { ProgressView("Opening library…") }
            else if model.photos.isEmpty { Text("Open a photo folder to begin").font(StudioStyle.title).foregroundStyle(StudioStyle.textSecondary) }
        }
    }

    private var assistant: some View {
        AssistantDock(title: model.question == nil ? model.status : "A decision for you",
                      detail: model.estimatedModelCalls == nil ? "\(model.scopePhotos.count) photos · \(model.scope.rawValue)" : model.approvalEstimate,
                      busy: model.isRunning && model.question == nil && model.estimatedModelCalls == nil,
                      progress: model.isRunning ? Double(model.done) / Double(max(1, model.total)) : nil,
                      reviewShown: model.reviewShown, style: assistantStyle,
                      toggleReview: { model.reviewShown.toggle() }) {
            VStack(spacing: 10) {
                HStack {
                    Picker("Scope", selection: $model.scope) {
                        Text("Selected · \(model.selectedPhotos.count)").tag(StudioLibraryScope.selected)
                        Text("Current view · \(model.photos.count)").tag(StudioLibraryScope.currentView)
                        Text("Entire library · \(model.photos.count)").tag(StudioLibraryScope.entireLibrary)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().accessibilityIdentifier("libraryScope")
                    .disabled(model.isRunning)
                    Spacer()
                    backend
                }.font(StudioStyle.label)
                HStack(alignment: .bottom, spacing: 10) {
                    TextField(model.voice.isRecording ? "Listening…" : "Describe an edit for these photos", text: $model.instruction, axis: .vertical)
                        .textFieldStyle(.plain).font(StudioStyle.title).lineLimit(1...3)
                        .disabled(model.isRunning || model.voice.isRecording)
                        .onSubmit { if model.canRun { model.run() } }
                        .accessibilityIdentifier("libraryPrompt")
                    StudioMicButton(voice: model.voice, disabled: model.isRunning,
                                    heard: { model.instruction = StudioVoice.adding($0, to: model.instruction) }) { model.issue = $0 }
                    if model.isRunning {
                        Button(action: model.stop) { Image(systemName: "stop.fill").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).foregroundStyle(StudioStyle.accent)
                            .disabled(model.isStopping).help("Stop editing").accessibilityIdentifier("libraryStop")
                    } else {
                        Button(action: model.run) {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 30, height: 30)
                                .background(StudioStyle.accent, in: Circle())
                        }
                        .buttonStyle(.plain).disabled(!model.canRun || model.voice.isRecording || model.voice.isTranscribing)
                        .help("Run on \(model.scopePhotos.count) photos").accessibilityLabel("Run").accessibilityIdentifier("libraryRun")
                    }
                }
            }
            .padding(14).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.promptRadius))
            .overlay { RoundedRectangle(cornerRadius: StudioStyle.promptRadius).strokeBorder(StudioStyle.line) }
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    private var footer: some View {
        HStack(spacing: StudioStyle.barSpacing) {
            Text(model.backends.isLoading ? model.backends.status ?? model.status : model.status).lineLimit(1)
            Spacer()
            Text("\(model.done)/\(model.total) · \(model.modelCalls) model calls · \(studioDollars(model.totalCost))")
                .monospacedDigit()
        }
        .font(StudioStyle.caption).foregroundStyle(StudioStyle.textSecondary)
        .padding(.horizontal, StudioStyle.barInset).frame(height: StudioStyle.bottomBarHeight)
    }

    private var sidebar: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Lumen").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        StudioIconButton(symbol: "sidebar.right", help: "Hide details") { model.reviewShown = false }
                    }.id("libraryReviewTop")
                    if let issue = model.issue ?? model.backends.issue {
                        Text(issue).font(StudioStyle.label).foregroundStyle(StudioStyle.danger).textSelection(.enabled)
                    }
                    if let question = model.question {
                        StudioQuestionCard(question: question.question, options: question.options, recommended: question.recommended,
                                           floating: true, disabled: model.isStopping) { option in Task { await model.answer(option) } }
                    } else if let decision = model.recentDecision {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Decided: \(decision.answer)").font(StudioStyle.title)
                            Text(decision.question.question).font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
                        }
                        .padding(12).background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.cardRadius, style: .continuous))
                    }
                    if let plan = model.plan, model.estimatedModelCalls != nil {
                        PlanReview(plan: plan, targets: plan.targetPhotos ?? model.runTargets,
                                   instructions: $model.instructionOverrides, excluded: $model.excludedPhotos,
                                   estimate: model.approvalEstimate, operations: model.plannedOperations,
                                   busy: model.isCheckingApproval || model.isStopping,
                                   canApprove: !model.isCheckingApproval && model.approvalIssue == nil, style: assistantStyle,
                                   changed: model.draftChanged, approve: { Task { await model.approve() } }, cancel: model.stop) { photo in
                            LibraryReviewThumbnail(model: model, photo: photo, thumbnails: thumbnails)
                        }
                    } else if let summary = model.summary ?? model.stoppedSnapshot?.summary {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.stoppedSnapshot == nil
                                 ? (summary.photos.contains(where: \.failed) ? "Finished with issues" : "Library finished")
                                 : "Library stopped").font(.system(size: 16, weight: .semibold))
                            Text(model.completionDetail).font(StudioStyle.title)
                            Text("\(model.stoppedSnapshot?.startedModelCalls ?? summary.modelCalls) model calls · \(studioDollars(summary.totalCost))")
                                .font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
                            if model.stoppedSnapshot?.unfinishedPhotoIDs.isEmpty == false {
                                Text("Unfinished photos may contain partial edits. Review them before exporting.")
                                    .font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
                            }
                            Button("Show results folder", action: model.revealOutput).font(StudioStyle.label)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(StudioStyle.raised, in: RoundedRectangle(cornerRadius: StudioStyle.promptRadius))
                    } else if !model.isRunning {
                        configuration
                    }
                    if !model.events.isEmpty {
                        Text("Activity").font(StudioStyle.section).foregroundStyle(StudioStyle.textSecondary)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.events) { event in
                                TimelineRow(entry: event, isLast: event.id == model.events.last?.id)
                                    .frame(width: 300, alignment: .leading).clipped().id(event.id)
                            }
                        }
                    }
                    if !model.decisions.isEmpty {
                        DisclosureGroup("Decisions · \(model.decisions.count)") {
                            ForEach(Array(model.decisions.enumerated()), id: \.offset) { _, answer in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(answer.question.question).foregroundStyle(StudioStyle.textSecondary)
                                    Text("Decided: \(answer.answer)")
                                }.font(StudioStyle.label).padding(.vertical, 8)
                            }
                        }.font(StudioStyle.label)
                    }
                }.padding(StudioStyle.gutter)
            }
            .onChange(of: model.events.last?.id) {
                if model.summary == nil, model.estimatedModelCalls == nil, model.question == nil, let id = model.events.last?.id {
                    scroll.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: model.summary != nil) {
                if model.summary != nil { scroll.scrollTo("libraryReviewTop", anchor: .top) }
            }
        }
        .accessibilityIdentifier("libraryReviewSidebar")
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $model.mode) {
                Text("Autonomous").tag(BatchMode.autonomous)
                Text("Ask me").tag(BatchMode.askWhenUnsure)
                Text("Plan first").tag(BatchMode.planFirst)
            }.accessibilityIdentifier("libraryMode")
            Toggle("Auto tone and colour", isOn: $model.auto)
            Picker("Straighten", selection: $model.straighten) {
                ForEach(LibraryStraighten.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Flag misfires", isOn: $model.flagMisfires)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("Quality threshold"); Spacer(); Text(model.qualityThreshold.formatted(.number.precision(.fractionLength(2)))) }
                Slider(value: $model.qualityThreshold, in: 0...1).controlSize(.mini).accessibilityLabel("Quality threshold")
                Text("Photos below this get a closer look.").font(StudioStyle.caption).foregroundStyle(StudioStyle.textTertiary)
            }
            Text("Current view contains this whole folder. Hover a photo to select it, or use its context menu.")
                .font(StudioStyle.caption).foregroundStyle(StudioStyle.textSecondary)
            Text("Results").font(StudioStyle.section).foregroundStyle(StudioStyle.textSecondary)
            Text(model.output?.path ?? "").font(StudioStyle.caption).foregroundStyle(StudioStyle.textSecondary)
                .lineLimit(2).help(model.output?.path ?? "")
            Button("Change folder…", action: model.chooseOutput)
        }
        .font(StudioStyle.body).toggleStyle(.switch).controlSize(.small).disabled(!model.canRun)
    }

    private var backend: some View {
        Menu {
            ForEach(StudioScript.Backend.allCases, id: \.self) { backend in
                let availability = model.backends.availability(for: backend)
                Button { model.backends.choose(backend) } label: {
                    if model.backends.selection == backend { Label(backend.title, systemImage: "checkmark") }
                    else { Text(backend.title) }
                }.disabled(!availability.isEnabled).help(availability.help)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkle").foregroundStyle(StudioStyle.accent)
                Text(model.backends.selection.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isRunning)
        .accessibilityLabel("Planner")
        .simultaneousGesture(TapGesture().onEnded { Task { await model.backends.refreshAvailability() } })
    }
}

private struct LibraryReviewThumbnail: View {
    let model: StudioLibraryModel
    let photo: PhotoID
    let thumbnails: LibraryThumbnails
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            StudioStyle.canvas
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(StudioStyle.textTertiary) }
        }
        .task(id: "\(model.folder?.path ?? "")/\(photo.rawValue)") {
            guard let folder = model.folder else { return }
            image = try? await thumbnails.image(key: "\(folder.path)/\(photo.rawValue):original") {
                try await LibraryThumbnailReader.shared.read(folder.appendingPathComponent(photo.rawValue))
            }
        }
    }
}

private struct LibraryPhotoCell: View {
    let model: StudioLibraryModel
    let photo: PhotoID
    let thumbnails: LibraryThumbnails
    let highlighted: Bool
    let open: () -> Void
    @State private var image: NSImage?
    @State private var originalSize: PixelSize?
    @State private var issue: String?
    @State private var hovering = false
    @State private var showingInfo = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var revision: String { "\(model.folder?.path ?? ""):\(model.compare):\(model.states[photo]?.revision ?? 0)" }
    private var selected: Bool { model.selectedPhotos.contains(photo) }

    /// The row keeps a fixed height, while each contour follows the fitted photo itself.
    /// Details and selection controls never reserve a metadata strip or move the image.
    var body: some View {
        GeometryReader { geometry in
            let size = fittedSize(in: geometry.size)
            Button(action: open) {
                ZStack {
                    StudioStyle.raised
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: issue == nil ? "photo" : "exclamationmark.triangle").foregroundStyle(StudioStyle.textTertiary) }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: StudioStyle.photoRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: StudioStyle.photoRadius, style: .continuous)
                    .strokeBorder(highlighted || selected ? StudioStyle.accent : StudioStyle.line.opacity(hovering ? 1 : 0),
                                  lineWidth: highlighted || selected ? 2 : 1) }
                .contentShape(RoundedRectangle(cornerRadius: StudioStyle.photoRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(photo.rawValue)
            .accessibilityValue(photoInformation)
            .accessibilityHint(model.isRunning ? "Stop the library to inspect layers" : "Open this photo and its layers")
            .overlay(alignment: .topLeading) {
                Button { model.toggleSelection(photo) } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? StudioStyle.accent : .white)
                        .frame(width: 20, height: 20)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain).padding(6).disabled(model.isRunning)
                .opacity(hovering || selected ? 1 : 0)
                .allowsHitTesting(hovering || selected)
                .accessibilityLabel("Select \(photo.rawValue)")
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityIdentifier("librarySelect.\(photo.rawValue)")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 140)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .help(photoInformation)
        .contextMenu {
            Button("Photo Info…") { showingInfo = true }
            Button("Open Photo", action: open).disabled(model.isRunning)
            Button(selected ? "Deselect Photo" : "Select Photo") { model.toggleSelection(photo) }.disabled(model.isRunning)
        }
        .popover(isPresented: $showingInfo) {
            Text(photoInformation).font(StudioStyle.body).textSelection(.enabled)
                .padding(16).frame(minWidth: 220, maxWidth: 340, alignment: .leading)
        }
        .task(id: revision) {
            guard let folder = model.folder else { return }
            originalSize = await LibraryThumbnailReader.shared.size(folder.appendingPathComponent(photo.rawValue))
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

    private func fittedSize(in available: CGSize) -> CGSize {
        let source = image?.size ?? originalSize.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) } ?? CGSize(width: 4, height: 3)
        let scale = min(available.width / max(1, source.width), available.height / max(1, source.height))
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private var photoInformation: String {
        var lines = [photo.rawValue]
        if let size = model.states[photo]?.facts?.size ?? originalSize { lines.append("\(size.width) × \(size.height) px") }
        let badges = LibraryBadge.allCases.filter { model.states[photo]?.badges.contains($0) == true }.map(\.rawValue)
        if !badges.isEmpty { lines.append(badges.joined(separator: " · ")) }
        if let reason = model.states[photo]?.reason, !reason.isEmpty { lines.append(reason) }
        if let issue { lines.append(issue) }
        return lines.joined(separator: "\n")
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
    /// Metadata only; photo help never starts model analysis or full-resolution rendering.
    func size(_ url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let rotated = (properties[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
        return PixelSize(width: rotated ? height : width, height: rotated ? width : height)
    }

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
