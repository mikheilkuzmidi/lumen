import Accelerate
import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

/// The models an edit calls, by the names people know them, for the live view's labels.
public struct LiveEditModels: Equatable, Sendable {
    public var planner: String
    public var segmenter: String
    public var generator: String

    public init(planner: String = "Muse Spark", segmenter: String = "SAM 3.1", generator: String = "Muse Image") {
        self.planner = planner
        self.segmenter = segmenter
        self.generator = generator
    }

    public static let meta = LiveEditModels()
}

/// What an edit is doing to the photo right now, followed from the agent's events, for the live view over the photo.
public struct LiveEditState: Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// The planner reads the instruction and the photo.
        case reading
        /// The segmenter looks for what the plan names.
        case finding
        /// It found it: the mask is shown.
        case found
        /// The image model redraws the region.
        case generating
        /// A plain adjustment of the region, with no redraw.
        case adjusting
        /// The change is in the photo; the agent checks it.
        case checking
        /// The check passed.
        case accepted
    }

    public enum Action: String, Equatable, Sendable { case redraw, remove, restyle }

    public private(set) var phase: Phase?
    public private(set) var regionName: String?
    public private(set) var action: Action = .redraw
    /// The critic asked for changes, so the planner is revising.
    public private(set) var revising = false
    /// The mask of the region being worked on and where it lies in the photo.
    public private(set) var mask: MaskData?
    public private(set) var box: NormalizedRect?
    /// Changes whenever `mask` does, so a view rebuilds its mask images only then.
    public private(set) var maskRevision = 0
    public var models: LiveEditModels
    private var found: [String: Segment] = [:]

    public init(models: LiveEditModels = .meta) {
        self.models = models
    }

    /// A new instruction: the planner starts reading.
    public mutating func begin() {
        self = LiveEditState(models: models)
        phase = .reading
    }

    /// The run ended or was stopped.
    public mutating func end() {
        phase = nil
    }

    public mutating func receive(_ event: AgentEvent) {
        guard phase != nil else { return }
        switch event {
        case .planned, .answered:
            if phase == .reading || phase == .checking { phase = .reading }
        case .question:
            break
        case .stepStarted(_, let step):
            switch step {
            case .select(let selection):
                regionName = selection.concept ?? selection.id
                setMask(nil)
                phase = .finding
            case .regenerate(let step):
                work(on: step.region, action: .redraw)
            case .remove(let step):
                work(on: step.region, action: .remove)
            case .style(let step):
                work(on: step.region, action: .restyle)
            case .adjust(let step):
                if let region = step.region, let segment = found[region] {
                    show(segment)
                } else {
                    regionName = nil
                    setMask(nil)
                }
                phase = .adjusting
            case .crop, .revert, .finish:
                break
            }
        case .selected(let region, let segment):
            found[region] = segment
            show(segment)
            phase = .found
        case .applied, .reverted:
            phase = .checking
        case .critiqued(let critique):
            revising = !critique.satisfied && !critique.steps.isEmpty
            phase = critique.satisfied ? .accepted : (revising ? .reading : .checking)
        case .finished:
            if phase != .accepted { phase = nil }
        case .trace(let trace):
            if trace.kind == .failure { phase = nil }
        }
    }

    /// What the live view says about the current phase.
    public var label: String? { label(for: phase) }

    /// What the live view says about a phase, with this edit's region and models.
    public func label(for phase: Phase?) -> String? {
        guard let phase else { return nil }
        let name = regionName.map(Self.named)
        switch phase {
        case .reading: return models.planner + (revising ? " · revising the plan" : " · reading the instruction")
        case .finding: return models.segmenter + " · finding " + (name ?? "the region")
        case .found: return models.segmenter + " · " + (regionName ?? "found")
        case .generating:
            let verb = switch action { case .redraw: "redrawing "; case .remove: "removing "; case .restyle: "restyling " }
            return models.generator + " · " + verb + (name ?? "the photo")
        case .adjusting: return "Adjusting " + (name ?? "the photo")
        case .checking: return "Checking with " + models.segmenter + " and " + models.planner
        case .accepted: return "Result accepted"
        }
    }

    private mutating func work(on region: String?, action: Action) {
        self.action = action
        if let region, let segment = found[region] { show(segment) } else if mask == nil { regionName = region }
        phase = .generating
    }

    private mutating func show(_ segment: Segment) {
        regionName = segment.label
        box = segment.box
        setMask(segment.mask)
    }

    private mutating func setMask(_ next: MaskData?) {
        guard next != mask else { return }
        mask = next
        if next == nil { box = nil }
        maskRevision += 1
    }

    /// "jacket" reads as "the jacket"; "his jacket" or "the sky" keep their own word.
    static func named(_ name: String) -> String {
        let lower = name.lowercased()
        let owned = ["the ", "his ", "her ", "their ", "its ", "a ", "an ", "my ", "your "]
        return owned.contains { lower.hasPrefix($0) } ? name : "the " + name
    }
}

/// A mask drawn for the live view: a fill and an edge band as white alpha images, made once per selection.
public struct LiveEditMask: @unchecked Sendable {
    public let fill: CGImage
    public let edge: CGImage
    /// Where the mask lies, as a fraction of the photo, top-left origin.
    public let box: NormalizedRect

    public init?(mask: MaskData, box: NormalizedRect? = nil, maxLongEdge: Int = 768) {
        let width = mask.size.width, height = mask.size.height
        guard width > 0, height > 0, mask.coverage.count == width * height, maxLongEdge > 0 else { return nil }
        let scale = min(1, Double(maxLongEdge) / Double(max(width, height)))
        let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
        var small = [UInt8](repeating: 0, count: w * h)
        let scaled: vImage_Error = mask.coverage.withUnsafeBytes { source in
            small.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress), height: vImagePixelCount(height),
                                         width: vImagePixelCount(width), rowBytes: width)
                var to = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                return vImageScale_Planar8(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard scaled == kvImageNoError else { return nil }
        // The edge is what an erosion takes away: a band a couple of pixels wide at the drawn size.
        let radius = max(1, max(w, h) / 300), kernel = vImagePixelCount(2 * radius + 1)
        var eroded = [UInt8](repeating: 0, count: w * h)
        let morphed: vImage_Error = small.withUnsafeMutableBytes { source in
            eroded.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var to = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                return vImageMin_Planar8(&from, &to, nil, 0, 0, kernel, kernel, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard morphed == kvImageNoError else { return nil }
        var edgeAlpha = [UInt8](repeating: 0, count: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let index = y * w + x, value = small[index]
                edgeAlpha[index] = value &- min(value, eroded[index])
                if value > 32 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0, let fill = Self.image(alpha: small, width: w, height: h),
              let edge = Self.image(alpha: edgeAlpha, width: w, height: h) else { return nil }
        self.fill = fill
        self.edge = edge
        self.box = box ?? NormalizedRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h),
                                         width: Double(maxX - minX + 1) / Double(w), height: Double(maxY - minY + 1) / Double(h))
    }

    /// White, as opaque as the alpha says: an alpha mask every way a canvas is drawn honours.
    static func image(alpha: [UInt8], width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: alpha.count * 4)
        for index in alpha.indices {
            let value = alpha[index]
            pixels[index * 4] = value; pixels[index * 4 + 1] = value; pixels[index * 4 + 2] = value; pixels[index * 4 + 3] = value
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The edit as it happens, drawn over the photo it changes: one light pass while the plan is made, the mask as the
/// segmenter finds it, a veil with light moving through it while the region is redrawn, the veil lifting as the new
/// pixels land, and a slow pulse on the edge while the result is checked. Lay it over the photo's frame exactly.
public struct LiveEditOverlay: View {
    let state: LiveEditState
    let style: AssistantStyle
    /// Off for a host that already draws its own selection reveal; the later phases still show.
    let drawsSelection: Bool
    @State private var art: LiveEditMask?
    @State private var sweep: CGFloat = -0.5
    @State private var band: CGFloat = -0.4
    @State private var banding = false
    @State private var tint = 0.0
    @State private var veil = 0.0
    @State private var edge = 0.0
    @State private var visible = 0.0
    @State private var flash = 0.0
    @State private var pulse = 1.0
    /// The phase on screen. It trails the edit's by up to `foundHold` after a selection, so what the segmenter found
    /// is seen before the redraw covers it: the redraw often starts within half a second.
    @State private var shown: LiveEditState.Phase?
    @State private var foundAt: Date?
    @State private var pending: Task<Void, Never>?
    static let foundHold: TimeInterval = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: LiveEditState, style: AssistantStyle = AssistantStyle(), drawsSelection: Bool = true) {
        self.state = state
        self.style = style
        self.drawsSelection = drawsSelection
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if !reduceMotion {
                    light(width: size.width * 0.38, height: size.height, at: sweep, in: size, opacity: 0.16)
                        .opacity(shown == .reading || shown == .finding ? 1 : 0)
                }
                if let art {
                    let fill = Image(decorative: art.fill, scale: 1).resizable().interpolation(.high)
                    style.accent.opacity(tint).mask { fill }
                    Color.black.opacity(veil).mask { fill }
                    if !reduceMotion {
                        light(width: size.width * 0.3, height: size.height, at: band, in: size, opacity: 0.3)
                            .opacity(banding ? 1 : 0).mask { fill }
                        light(width: size.width * 0.45, height: size.height, at: sweep, in: size, opacity: 0.45)
                            .opacity(flash).mask { fill }
                    }
                    style.accent.opacity(edge)
                        .mask { Image(decorative: art.edge, scale: 1).resizable().interpolation(.high) }
                        .opacity(pulse)
                }
                if let label = state.label(for: shown) {
                    chip(label).position(chipPosition(in: size))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .opacity(visible)
        .allowsHitTesting(false)
        .task(id: state.maskRevision) {
            guard let mask = state.mask else { art = nil; return }
            let box = state.box
            let made = await Task.detached(priority: .userInitiated) { LiveEditMask(mask: mask, box: box) }.value
            guard !Task.isCancelled else { return }
            // The new mask starts clear, so its edge draws in and its tint fades up.
            animate(nil) { art = made; edge = 0; tint = 0; veil = 0 }
            enter(shown)
        }
        .onAppear { follow(state.phase) }
        .onChange(of: state.phase) { _, phase in follow(phase) }
        .onDisappear { pending?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label(for: shown) ?? "")
        .accessibilityValue(shown?.rawValue ?? "idle")
        .accessibilityIdentifier("lumenLive")
    }

    private func light(width: CGFloat, height: CGFloat, at position: CGFloat, in size: CGSize, opacity: Double) -> some View {
        LinearGradient(colors: [.clear, .white.opacity(opacity), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: width, height: height)
            .offset(x: position * size.width)
            .frame(width: size.width, height: size.height, alignment: .leading)
    }

    private func chip(_ label: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(shown == .accepted ? Color.green : style.accent).frame(width: 6, height: 6)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(style.primary).lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(style.raised.opacity(0.92), in: Capsule())
        .overlay { Capsule().strokeBorder(style.line) }
        .fixedSize()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: label)
    }

    /// Above the mask's top-left corner when there is one, else the photo's; always inside the photo.
    private func chipPosition(in size: CGSize) -> CGPoint {
        let estimate = CGSize(width: min(size.width - 16, CGFloat(state.label(for: shown)?.count ?? 0) * 6.6 + 34), height: 26)
        var point = CGPoint(x: 12 + estimate.width / 2, y: 12 + estimate.height / 2)
        if let box = art?.box, shown != .reading {
            point = CGPoint(x: box.x * size.width + estimate.width / 2, y: box.y * size.height - estimate.height / 2 - 8)
        }
        point.x = min(max(point.x, 8 + estimate.width / 2), size.width - 8 - estimate.width / 2)
        point.y = min(max(point.y, 8 + estimate.height / 2), size.height - 8 - estimate.height / 2)
        return point
    }

    private func animate(_ animation: Animation?, _ change: () -> Void) {
        if reduceMotion || animation == nil {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, change)
        } else {
            withAnimation(animation, change)
        }
    }

    private func stopBand() {
        animate(nil) { band = -0.4; banding = false; pulse = 1 }
    }

    private func breathe(_ seconds: Double, low: Double) {
        guard !reduceMotion else { return }
        animate(nil) { pulse = 1 }
        withAnimation(.easeInOut(duration: seconds).repeatForever(autoreverses: true)) { pulse = low }
    }

    /// Shows the edit's phase, holding a fresh selection on screen for `foundHold` first.
    private func follow(_ phase: LiveEditState.Phase?) {
        pending?.cancel(); pending = nil
        if phase == .found { foundAt = Date() }
        if shown == .found, phase != .found, phase != nil, let foundAt {
            let wait = Self.foundHold - Date().timeIntervalSince(foundAt)
            if wait > 0 {
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    show(state.phase)
                }
                return
            }
        }
        show(phase)
    }

    private func show(_ phase: LiveEditState.Phase?) {
        shown = phase
        enter(phase)
    }

    private func enter(_ phase: LiveEditState.Phase?) {
        let selection = drawsSelection
        switch phase {
        case nil:
            stopBand()
            animate(.easeOut(duration: 0.35)) { visible = 0 }
        case .reading, .finding:
            stopBand()
            animate(.easeInOut(duration: 0.3)) { visible = 1; tint = 0; veil = 0; edge = 0; flash = 0 }
            if phase == .reading {
                animate(nil) { sweep = -0.5 }
                animate(.easeInOut(duration: 1.6)) { sweep = 1.1 }
            }
        case .found, .adjusting:
            stopBand()
            animate(.easeInOut(duration: 0.3)) { visible = 1; veil = 0; flash = 0 }
            animate(.easeOut(duration: 0.55)) { edge = selection ? 1 : 0 }
            animate(.easeInOut(duration: 0.6).delay(0.15)) { tint = selection ? (phase == .adjusting ? 0.16 : 0.3) : 0 }
        case .generating:
            animate(.easeInOut(duration: 0.3)) { visible = 1; flash = 0 }
            animate(.easeInOut(duration: 0.5)) { veil = 0.34; tint = 0.14 }
            animate(.easeOut(duration: 0.4)) { edge = 1 }
            if !reduceMotion && !banding {
                animate(nil) { band = -0.4; banding = true }
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { band = 1.05 }
                breathe(0.9, low: 0.55)
            }
        case .checking:
            let lifting = veil > 0
            stopBand()
            animate(.easeInOut(duration: 0.3)) { visible = 1 }
            animate(.easeOut(duration: 0.9)) { veil = 0; tint = 0 }
            if lifting && !reduceMotion {
                // The redraw lands: one bright pass over the region as the veil lifts.
                animate(nil) { sweep = -0.5; flash = 1 }
                withAnimation(.easeInOut(duration: 0.9)) { sweep = 1.1 }
                withAnimation(.easeOut(duration: 0.4).delay(0.7)) { flash = 0 }
            }
            animate(.easeInOut(duration: 0.5)) { edge = 0.85 }
            breathe(1.2, low: 0.4)
        case .accepted:
            stopBand()
            animate(.easeOut(duration: 0.6)) { veil = 0; tint = 0; edge = 0; flash = 0; visible = 1 }
            animate(.easeOut(duration: 0.5).delay(1.6)) { visible = 0 }
        }
    }
}
