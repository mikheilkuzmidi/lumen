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
                    HStack(spacing: 8) {
                        if model.isRunning { ProgressView().controlSize(.mini) }
                        Text(model.backends.isLoading ? model.backends.status ?? model.status : model.status).lineLimit(1)
                        Spacer()
                        Text("\(model.done)/\(model.total) · \(model.modelCalls) model calls · \(studioDollars(model.totalCost))")
                            .monospacedDigit()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(18)
                    // Not animated: a capture of a finished library showed the bar still catching up.
                    ProgressView(value: Double(model.done), total: Double(max(1, model.total)))
                        .tint(StudioStyle.accent).progressViewStyle(.linear)
                        .animation(nil, value: model.done)
                }
                Rectangle().fill(StudioStyle.line).frame(width: 1)
                sidebar.frame(width: 300)
            }
        }
        .background(StudioStyle.panel)
        .preferredColorScheme(.dark).tint(StudioStyle.accent)
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 16).strokeBorder(StudioStyle.accent, lineWidth: 2).padding(8).allowsHitTesting(false) } }
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
        HStack(spacing: 18) {
            Text("LUMEN").font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(3.5).foregroundStyle(StudioStyle.accent)
            Rectangle().fill(StudioStyle.line).frame(width: 1, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.folder?.lastPathComponent ?? "Library").font(.system(size: 12, weight: .medium))
                Text("\(model.photos.count) photos").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Before", isOn: $model.compare).toggleStyle(.button).font(.system(size: 11))
                .help("Show the original photos")
            Button(action: model.revealOutput) { Label("Results", systemImage: "folder") }
                .help("Reveal the output folder").disabled(model.output == nil)
            SettingsLink { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
        }
        .buttonStyle(.borderless).padding(.leading, 88).padding(.trailing, 22).frame(height: 60)
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
            else if model.photos.isEmpty { Text("No photos in this folder").font(.system(size: 14)).foregroundStyle(.secondary) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("EDIT THE LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(StudioStyle.accent)
                    TextField("Describe a change, or run the base pass", text: $model.instruction, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(3...6)
                        .padding(14).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
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
                        Text("Photos below this get a closer look.").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    backend
                    VStack(alignment: .leading, spacing: 7) {
                        Text("RESULTS").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                        Text(model.output?.path ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).help(model.output?.path ?? "")
                        Button("Change folder…", action: model.chooseOutput)
                    }
                }
                .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                .disabled(model.isRunning || !model.canRun)
                .padding(20)
            }
            .frame(maxHeight: 480)
            HStack {
                Button(action: model.run) { Label("Run", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).foregroundStyle(StudioStyle.canvas).disabled(!model.canRun)
                Button(action: model.stop) { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!model.isRunning || model.isStopping)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
            if let issue = model.issue ?? model.backends.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled).padding(16)
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
                                        Text(answer.question.question).foregroundStyle(.secondary)
                                        Text("Decided: \(answer.answer)").foregroundStyle(StudioStyle.accent)
                                    }.font(.system(size: 11)).padding(.vertical, 8)
                                }
                            }.font(.system(size: 11))
                        }
                    }.padding(20)
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
            Label(model.backends.selection.title, systemImage: "circle.fill").font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton).foregroundStyle(.secondary)
        .accessibilityLabel("Planner")
        .simultaneousGesture(TapGesture().onEnded { Task { await model.backends.refreshAvailability() } })
    }

    private func questionCard(_ question: BatchQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.question).font(.system(size: 14, weight: .medium))
            ViewThatFits(in: .horizontal) {
                HStack { options(question) }
                VStack(alignment: .leading) { options(question) }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.accent.opacity(0.06))
    }

    private func options(_ question: BatchQuestion) -> some View {
        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
            Button { Task { await model.answer(option) } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option).font(.system(size: 12))
                    if index == question.recommended { Text("Recommended").font(.system(size: 9)).foregroundStyle(StudioStyle.accent) }
                }
            }
            .buttonStyle(.bordered).disabled(model.isStopping)
        }
    }

    private func decisionCard(_ answer: BatchAnswer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Decided: \(answer.answer)").font(.system(size: 14, weight: .medium))
            Text(answer.question.question).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.accent.opacity(0.06))
    }

    private func planPanel(_ plan: BatchPlan, calls: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.summary).font(.system(size: 14, weight: .medium))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.groups) { group in
                        Button { model.selectedGroup = group.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(group.title) · \(group.photos.count) \(group.photos.count == 1 ? "photo" : "photos")").font(.system(size: 12, weight: .medium))
                                Text(group.instruction ?? "Base pass").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(StudioStyle.accent.opacity(model.selectedGroup == group.id ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 180)
            HStack {
                Text("About \(calls) more model calls" + (plan.estimatedCost.map { ", about " + studioDollars($0, estimated: true) + " USD" } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: model.stop)
                Button("Go ahead") { Task { await model.approve() } }.buttonStyle(.borderedProminent).foregroundStyle(StudioStyle.canvas)
            }.disabled(model.isStopping)
        }.padding(20)
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
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035))
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: issue == nil ? "photo" : "exclamationmark.triangle").foregroundStyle(.tertiary) }
                }
                .frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(highlighted ? StudioStyle.accent : StudioStyle.line, lineWidth: highlighted ? 2 : 1) }
                Text(photo.rawValue).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
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
                    .foregroundStyle(badge == .failed || badge == .attention || badge == .misfire ? Color.orange : StudioStyle.accent)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Color.white.opacity(0.04), in: Capsule())
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
