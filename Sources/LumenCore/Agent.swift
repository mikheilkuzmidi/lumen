import Foundation

/// What went wrong, in terms a person can act on.
public enum LumenError: Error, Equatable, Sendable, LocalizedError {
    case missingKey
    case paymentRequired
    case rateLimited(retryAfter: TimeInterval?)
    case refused(String)
    case invalidResponse(String)
    case timedOut
    case cancelled
    case unknownRegion(String)
    case http(status: Int, message: String)
    case notBuilt(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No Meta API key. Set META_API_KEY or add one in Lumen Studio's settings."
        case .paymentRequired: "The Meta account has no credit left for this model."
        case .rateLimited(let after): "Meta is limiting requests" + (after.map { String(format: "; try again in %.0f s.", $0) } ?? ".")
        case .refused(let reason): "The model declined: \(reason)"
        case .invalidResponse(let detail): "The model's answer couldn't be used: \(detail)"
        case .timedOut: "The model took too long to answer."
        case .cancelled: "Stopped."
        case .unknownRegion(let id): "No region called “\(id)” was selected before this step."
        case .http(let status, let message): "The request failed (\(status)): \(message)"
        case .notBuilt(let what): "\(what) isn't built yet."
        }
    }
}

/// One thing that happened during an edit, for the timeline and the trace file.
public struct TraceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case plan, select, adjust, regenerate, remove, style, crop, revert, critique, finish, failure
    }

    public var kind: Kind
    /// The model that answered, for model calls.
    public var model: String?
    public var detail: String
    public var started: Date
    public var duration: TimeInterval
    /// The reported charge in US dollars; nil when the price or usage is unknown.
    public var cost: Double?
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?

    public init(kind: Kind, model: String? = nil, detail: String, started: Date, duration: TimeInterval,
                cost: Double? = nil, inputTokens: Int? = nil, cachedInputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.kind = kind
        self.model = model
        self.detail = detail
        self.started = started
        self.duration = duration
        self.cost = cost
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

public struct AgentConfiguration: Sendable {
    /// Steps attempted for one instruction, across every revision.
    public var maxSteps = 12
    /// Times the planner may look at its result and revise it.
    public var maxRevisions = 2
    /// The long edge of the photo the planner and critic see. Muse Spark reads a 1536 px photo as about 1,940 input
    /// tokens and a 1024 px one as about 860 (measured October 26), and plans as well from it.
    public var previewLongEdge = 1024
    /// The long edge of the photo SAM selects in, where detail decides how well a mask fits.
    public var selectionLongEdge = 1536
    /// The long edge of the close-up of each redrawn region the critic is shown, before and after.
    public var closeUpLongEdge = 768

    public init(maxSteps: Int = 12, maxRevisions: Int = 2, previewLongEdge: Int = 1024, selectionLongEdge: Int = 1536,
                closeUpLongEdge: Int = 768) {
        self.maxSteps = maxSteps
        self.maxRevisions = maxRevisions
        self.previewLongEdge = previewLongEdge
        self.selectionLongEdge = selectionLongEdge
        self.closeUpLongEdge = closeUpLongEdge
    }
}

/// What an edit reports as it goes.
public enum AgentEvent: Sendable {
    case planned(EditPlan)
    case stepStarted(index: Int, step: EditStep)
    case selected(region: String, segment: Segment)
    case applied(Layer)
    case reverted(Layer.ID)
    case critiqued(Critique)
    case finished(reason: String)
    case trace(TraceEvent)
}

/// Plans an instruction, carries out each step as a layer on the host, looks at the result and revises it.
public actor EditAgent {
    public let planner: any Planner
    public let segmenter: any Segmenter
    public let generator: any Generator
    public let host: any EditHost
    public let configuration: AgentConfiguration
    /// The masks and images retained by this agent's layers.
    public let assets = AssetStore()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var latestRun: Task<Void, Never>?
    private var regions: [String: Region] = [:]
    private var layers: [AppliedLayer] = []
    private var history: [String] = []
    /// Each region redrawn in this run: where, and how it looked close up before its first redraw.
    private var closeUpsBefore: [(region: String, rect: NormalizedRect, image: EncodedImage)] = []

    public init(planner: any Planner, segmenter: any Segmenter, generator: any Generator, host: any EditHost,
                configuration: AgentConfiguration = AgentConfiguration()) {
        self.planner = planner
        self.segmenter = segmenter
        self.generator = generator
        self.host = host
        self.configuration = configuration
    }

    /// Runs the instruction; `area` is where the user asked the agent to look. `maxRevisions` lowers the configured
    /// limit for this instruction only, as an app does when its credits run low.
    public nonisolated func run(_ instruction: String, area: NormalizedRect? = nil, maxRevisions: Int? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { events in
            let task = Task {
                await self.start(instruction, area: area, maxRevisions: maxRevisions, events: events)
            }
            events.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Stops the edits currently running on this agent.
    public func cancel() {
        for task in tasks.values { task.cancel() }
    }

    /// Forgets the edit's regions, layers and instructions for a new photo.
    public func reset() {
        cancel()
        regions.removeAll()
        layers.removeAll()
        history.removeAll()
    }

    private struct Region {
        var info: RegionInfo
        var mask: MaskData
        var asset: AssetID
        /// How many things SAM found for it: seven flowers are redrawn as seven, not as the one in the middle.
        var count = 1
    }

    private struct AppliedLayer {
        var id: Layer.ID
        var info: LayerInfo
    }

    private var regionInfo: [RegionInfo] { regions.values.map(\.info).sorted { $0.id < $1.id } }
    private var layerInfo: [LayerInfo] { layers.map(\.info) }

    private struct Run {
        var missing: Set<String> = []
        var done: [String] = []
        var steps = 0
        /// The regions this run changed, in the order it first changed them.
        var edited: [String] = []

        mutating func edit(_ region: String) {
            if !edited.contains(region) { edited.append(region) }
        }
    }

    private typealias Events = AsyncThrowingStream<AgentEvent, Error>.Continuation

    private func start(_ instruction: String, area: NormalizedRect?, maxRevisions: Int?, events: Events) async {
        let id = UUID()
        let previous = latestRun
        let limit = min(configuration.maxRevisions, maxRevisions ?? configuration.maxRevisions)
        let task = Task {
            await previous?.value
            await self.run(instruction, area: area, maxRevisions: limit, events: events)
        }
        latestRun = task
        tasks[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks[id] = nil
        if tasks.isEmpty { latestRun = nil }
    }

    private func run(_ instruction: String, area: NormalizedRect?, maxRevisions: Int, events: Events) async {
        do {
            try checkCancellation()
            var run = Run()
            var redraws: [String: Layer.ID] = [:]
            closeUpsBefore = []
            guard configuration.maxSteps > 0 else {
                finish("Step limit reached.", events: events)
                return
            }
            let before = try await host.render(maxLongEdge: configuration.previewLongEdge)
            try checkCancellation()
            let request = PlanRequest(instruction: instruction, image: before, area: area,
                                      regions: regionInfo, done: run.done, layers: layerInfo, history: history)
            history.append(instruction)
            let plan = try await call(.plan, model: planner.modelID, detail: instruction, events: events) {
                try await self.planner.plan(request)
            }
            var next = checked(plan, events: events)
            events.yield(.planned(next))
            var revisions = 0
            while true {
                // The first plan's finish still gets a look, unless it only took layers off, which leaves the photo
                // exactly as it was; only successful, simple revisions can finish directly.
                let onlyReverts = next.steps.contains { $0.type == "revert" } && next.steps.allSatisfy { ["revert", "finish"].contains($0.type) }
                if let reason = try await carryOut(next, area: area, run: &run, redraws: &redraws, events: events),
                   revisions > 0 || onlyReverts {
                    finish(reason, events: events)
                    return
                }
                try checkCancellation()
                if run.steps >= configuration.maxSteps {
                    finish("Step limit reached.", events: events)
                    return
                }
                let after = try await host.render(maxLongEdge: configuration.previewLongEdge)
                try checkCancellation()
                var closeUps: [CloseUp] = []
                for shot in closeUpsBefore {
                    let now = try await host.render(region: shot.rect, maxLongEdge: configuration.closeUpLongEdge)
                    let lost = try await host.lostDetail(before: shot.image, after: now)
                    closeUps.append(CloseUp(region: shot.region, before: shot.image, after: now, lostDetail: Array(lost.prefix(3))))
                }
                let measurements = try await measured(before: before, after: after, edited: run.edited)
                try checkCancellation()
                let request = CritiqueRequest(instruction: instruction, before: before, after: after,
                                              regions: regionInfo, done: run.done, layers: layerInfo,
                                              history: Array(history.dropLast()), closeUps: closeUps,
                                              measurements: measurements)
                let critique = try await call(.critique, model: planner.modelID, detail: "Check the edit", events: events) {
                    try await self.planner.critique(request)
                }
                events.yield(.critiqued(critique))
                if critique.satisfied {
                    finish(critique.notes, events: events)
                    return
                }
                guard revisions < max(0, maxRevisions) else {
                    finish("Revision limit reached. \(critique.notes)", events: events)
                    return
                }
                revisions += 1
                next = checked(EditPlan(summary: critique.notes, steps: critique.steps), events: events)
            }
        } catch {
            let error = cancellationError(error)
            note(.failure, error.localizedDescription, events: events)
            events.finish(throwing: error)
        }
    }

    /// Each region this run changed and the rest of the photo, or the whole photo when no region was changed, measured
    /// at the start of the instruction and now.
    private func measured(before: EncodedImage, after: EncodedImage, edited: [String]) async throws -> [RegionChange] {
        // A crop in this run frames the two renders differently, so their regions can't be compared.
        guard before.size == after.size else { return [] }
        let masks = edited.compactMap { id in regions[id].map { (id, $0.mask) } }
        var parts: [(name: String, mask: MaskData?)] = masks.map { ($0.0, $0.1) }
        if let first = masks.first?.1 {
            let rest = masks.dropFirst().reduce(first) { $0.union($1.1) }.inverted()
            if rest.boundingBox != nil { parts.append(("rest of the photo", rest)) }
        } else {
            parts = [("photo", nil)]
        }
        var changes: [RegionChange] = []
        for part in parts {
            try checkCancellation()
            guard let was = try await host.measure(before, mask: part.mask),
                  let now = try await host.measure(after, mask: part.mask) else { continue }
            changes.append(RegionChange(region: part.name, before: was, after: now))
        }
        return changes
    }

    private func checked(_ plan: EditPlan, events: Events) -> EditPlan {
        let checked = plan.checked(knownRegions: Set(regions.keys), knownLayers: Set(layerInfo.map(\.id)))
        for detail in checked.notes { note(.plan, detail, events: events) }
        return checked.plan
    }

    private func carryOut(_ plan: EditPlan, area: NormalizedRect?, run: inout Run,
                          redraws: inout [String: Layer.ID], events: Events) async throws -> String? {
        // A plan's own finish is only believed when every step before it worked; otherwise the critic looks.
        var troubled = false
        var needsLook = false
        for step in plan.steps {
            try checkCancellation()
            guard run.steps < configuration.maxSteps else { return "Step limit reached." }
            let index = run.steps
            run.steps += 1
            events.yield(.stepStarted(index: index, step: step))
            if let region = step.region, run.missing.contains(region) {
                note(.failure, "Skipped \(step.type): nothing was found for \(region).", events: events)
                troubled = true
                continue
            }
            do {
                switch step {
                case .select(let selection):
                    needsLook = true
                    // A failed reselection must not leave a previous mask active under the same name.
                    regions[selection.id] = nil
                    run.missing.insert(selection.id)
                    if let region = try await select(selection, area: area, events: events) {
                        regions[selection.id] = region
                        run.missing.remove(selection.id)
                        run.done.append("\(title(selection.id)): selected")
                    } else {
                        troubled = true
                        run.done.append("\(title(selection.id)): nothing found for “\(selection.concept ?? selection.id)”")
                    }
                case .adjust(let adjustment):
                    let target = try adjustment.region.map { try self.region($0) }
                    let settings = AdjustmentKey.allCases.compactMap { key -> String? in
                        guard let value = adjustment.values[key] else { return nil }
                        let name = key.title
                        let magnitude = String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), abs(value))
                        return "\(name) \(value < 0 ? "−" : "+")\(magnitude)"
                    }.joined(separator: ", ")
                    let label = "\(title(adjustment.region ?? "photo")): \(settings)"
                    let layer = Layer(label: label, content: .adjustment(values: adjustment.values, mask: target?.asset))
                    try await apply(layer, kind: step.type, region: adjustment.region, events: events)
                    run.done.append(label)
                    if let region = adjustment.region { run.edit(region) }
                case .regenerate(let regeneration):
                    needsLook = true
                    let label = "\(title(regeneration.region)): redrawn as \(regeneration.prompt)"
                    let notes = try await redraw(try region(regeneration.region), prompt: regeneration.prompt,
                                                 label: label, kind: .regenerate, redraws: &redraws, events: events)
                    run.edit(regeneration.region)
                    run.done.append(label)
                    run.done.append(contentsOf: notes)
                    troubled = troubled || !notes.isEmpty
                case .remove(let removal):
                    needsLook = true
                    let label = "\(title(removal.region)): removed"
                    let notes = try await redraw(try region(removal.region), prompt: nil, label: label, kind: .remove,
                                                 redraws: &redraws, events: events)
                    run.edit(removal.region)
                    run.done.append(label)
                    run.done.append(contentsOf: notes)
                    troubled = troubled || !notes.isEmpty
                case .style(let restyle):
                    needsLook = true
                    try await self.restyle(restyle, run: &run, redraws: &redraws, events: events)
                case .crop(let crop):
                    let layer = Layer(label: "Photo: cropped", content: .crop(crop.rect))
                    try await apply(layer, kind: step.type, events: events)
                    run.done.append(layer.label)
                case .revert(let revert):
                    guard let layer = layers.first(where: { $0.info.id == revert.layer }) else {
                        throw LumenError.invalidResponse("No applied layer called “\(revert.layer)”.")
                    }
                    let started = Date()
                    try await host.remove(layer.id)
                    layers.removeAll { $0.id == layer.id }
                    redraws = redraws.filter { $0.value != layer.id }
                    run.done.append("Reverted \(layer.info.label)")
                    events.yield(.reverted(layer.id))
                    events.yield(.trace(TraceEvent(kind: .revert, detail: "Reverted \(layer.info.label) (\(layer.info.id))",
                                                   started: started, duration: max(0, Date().timeIntervalSince(started)))))
                    try checkCancellation()
                case .finish(let finish):
                    if troubled {
                        note(.plan, "Not finishing yet: a step didn't work, so the result is checked first.", events: events)
                        return nil
                    }
                    if needsLook { return nil }
                    return finish.reason
                }
            } catch {
                let error = cancellationError(error)
                if error as? LumenError == .cancelled { throw error }
                troubled = true
                note(.failure, "\(step.type): \(error.localizedDescription)", events: events)
            }
        }
        return nil
    }

    private func select(_ selection: Selection, area: NormalizedRect?, events: Events) async throws -> Region? {
        // Light falling across the photo needs no search: the region is the ramp itself.
        if let gradient = selection.gradient, selection.concept == nil, selection.box == nil, selection.points.isEmpty {
            let photo = await host.size()
            let scale = min(1, 1024 / Double(max(1, photo.longEdge)))
            let size = PixelSize(width: max(1, Int((Double(photo.width) * scale).rounded())),
                                 height: max(1, Int((Double(photo.height) * scale).rounded())))
            let ramp = MaskData.gradient(size: size, from: gradient.from, to: gradient.to)
            return try await region(selection, mask: selection.invert ? ramp.inverted() : ramp, label: "light", events: events)
        }
        let image = try await host.render(maxLongEdge: configuration.selectionLongEdge)
        try checkCancellation()
        // Every one of a kind is searched for over the whole photo (or the user's area), and all that is found is kept.
        let every = selection.every && selection.concept != nil
        let request = SegmentRequest(image: image, concept: selection.concept,
                                     box: every ? area : selection.box ?? area, points: every ? [] : selection.points)
        var segments = try await call(.select, model: segmenter.modelID,
                                      detail: "Find \(every ? "every " : "")\(selection.concept ?? selection.id)", events: events) {
            try await self.segmenter.segment(request)
        }
        if every {
            segments = try await coloured(segments, as: selection, in: image, events: events)
            guard !segments.isEmpty else {
                note(.select, "Nothing found for \(selection.id).", events: events)
                return nil
            }
            note(.select, "Found \(segments.count) \(selection.concept ?? selection.id) for \(selection.id).", events: events)
        }
        // When the planner says which one it means among several, keep only that: the segments under its points,
        // or else the ones that fit its box. If nothing fits (SAM found the neighbour's shirt but not this one),
        // nothing is kept, rather than the wrong one.
        if !every, selection.concept != nil, !segments.isEmpty, selection.box != nil || !selection.points.isEmpty {
            segments = Self.meant(segments, points: selection.points, box: selection.box)
            if segments.isEmpty {
                note(.select, "What was found for \(selection.id) is not where the planner pointed.", events: events)
            }
        }
        // The planner's box is a guess; when it rules out everything, search the whole photo (or the user's area).
        // That is only trusted when it finds exactly one: with several, it cannot say which was meant.
        if !every, !selection.colours.isEmpty, !segments.isEmpty {
            segments = try await coloured(segments, as: selection, in: image, events: events)
        }
        if segments.isEmpty, !every, selection.box != nil, selection.concept != nil {
            note(.select, "Nothing found inside the planner's box for \(selection.id); looking again without it.", events: events)
            let wider = SegmentRequest(image: image, concept: selection.concept, box: area, points: selection.points)
            let found = try await call(.select, model: segmenter.modelID, detail: "Find \(selection.concept ?? selection.id) again", events: events) {
                try await self.segmenter.segment(wider)
            }
            if found.count == 1 {
                segments = found
            } else if let near = Self.nearest(found, points: selection.points, box: selection.box) {
                // The planner's point or box missed the thing by a little (a car in a tall photo): the one clearly
                // nearest it is the one meant.
                segments = [near]
                note(.select, "Found \(found.count) of them elsewhere; kept the one nearest the planner's point.", events: events)
            } else if found.count > 1 {
                note(.select, "Found \(found.count) of them elsewhere; none is the one meant.", events: events)
            }
        }
        if segments.isEmpty, !every, let concept = selection.concept, request.box != nil || !request.points.isEmpty {
            let location = selection.box != nil ? "the planner's box" : request.box != nil ? "the selected area" : "the planner's points"
            note(.select, "Nothing was found for “\(concept)” by name; selecting from \(location).", events: events)
            let object = SegmentRequest(image: image, concept: nil, box: request.box, points: request.points)
            segments = try await call(.select, model: segmenter.modelID, detail: "Select \(concept) by location", events: events) {
                try await self.segmenter.segment(object)
            }
        }
        guard let first = segments.first else {
            note(.select, "Nothing found for \(selection.id).", events: events)
            return nil
        }
        var mask = segments.dropFirst().reduce(first.mask) { $0.union($1.mask) }
        guard mask.boundingBox != nil else {
            note(.select, "Nothing found for \(selection.id).", events: events)
            return nil
        }
        // The region is the shadow what was found casts on the ground, not the thing itself.
        if let tip = selection.shadowTip {
            mask = mask.castShadow(tip: tip)
        } else if selection.invert {
            mask = mask.inverted()
        }
        // What was found fades along the gradient: the sky nearest a low sun, say.
        if let gradient = selection.gradient {
            mask = mask.multiplied(by: MaskData.gradient(size: mask.size, from: gradient.from, to: gradient.to))
        }
        guard var found = try await region(selection, mask: mask, label: first.label, score: segments.count == 1 ? first.score : nil,
                                           events: events) else { return nil }
        found.count = selection.invert || selection.shadowTip != nil ? 1 : segments.count
        return found
    }

    /// Keeps a selection's mask as a region later steps can use.
    private func region(_ selection: Selection, mask: MaskData, label: String, score: Double? = nil,
                        events: Events) async throws -> Region? {
        guard let box = mask.boundingBox else {
            note(.select, "Nothing found for \(selection.id)\(selection.invert ? " after inversion" : "").", events: events)
            return nil
        }
        try checkCancellation()
        let asset = await assets.put(.mask(mask))
        do { try checkCancellation() } catch {
            await assets.remove(asset)
            throw error
        }
        let segment = Segment(label: selection.concept ?? label, box: box, mask: mask, score: score)
        events.yield(.selected(region: selection.id, segment: segment))
        return Region(info: RegionInfo(id: selection.id, concept: selection.concept, box: box, area: mask.area),
                      mask: mask, asset: asset)
    }

    /// The segments in one of the selection's colours, as the host measures them on `image`; all of them when it names
    /// none or the host can't measure.
    private func coloured(_ segments: [Segment], as selection: Selection, in image: EncodedImage,
                          events: Events) async throws -> [Segment] {
        guard !selection.colours.isEmpty else { return segments }
        var kept: [Segment] = []
        var families: [String] = []
        for segment in segments {
            try checkCancellation()
            guard let colour = try await host.measure(image, mask: segment.mask) else { return segments }
            families.append(colour.family)
            if selection.colours.contains(where: { colour.isIn($0) }) { kept.append(segment) }
        }
        let others = Set(zip(segments, families).filter { segment, _ in !kept.contains(segment) }.map(\.1)).sorted()
        note(.select, "Of \(segments.count) found, \(kept.count) are \(selection.colours.joined(separator: " or ")) (the others: "
             + "\(others.joined(separator: ", "))).", events: events)
        return kept
    }

    /// A colour's family, as a selection names colours.
    static func family(of colour: ColourMeasurement) -> String { colour.family }

    /// Among several things found, the one the planner most likely meant though its point or box missed it by a
    /// hair: the one whose box lies nearest the points' middle (or the box's centre), within a quarter of that thing's
    /// own size (at least 1% of the photo) and at most half as far as any other. A point near a neighbour's shirt is
    /// not near enough: nil, rather than the wrong one.
    static func nearest(_ segments: [Segment], points: [NormalizedPoint], box: NormalizedRect?) -> Segment? {
        let target: NormalizedPoint
        if !points.isEmpty {
            target = NormalizedPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                                     y: points.map(\.y).reduce(0, +) / Double(points.count))
        } else if let box {
            target = NormalizedPoint(x: box.x + box.width / 2, y: box.y + box.height / 2)
        } else {
            return nil
        }
        func distance(_ segment: Segment) -> Double {
            let box = segment.box
            let dx = max(box.x - target.x, 0, target.x - (box.x + box.width))
            let dy = max(box.y - target.y, 0, target.y - (box.y + box.height))
            return (dx * dx + dy * dy).squareRoot()
        }
        let ranked = segments.sorted { distance($0) < distance($1) }
        guard let first = ranked.first, distance(first) <= max(0.01, 0.25 * min(first.box.width, first.box.height)) else {
            return nil
        }
        if ranked.count > 1, distance(ranked[1]) < max(0.02, distance(first) * 2) { return nil }
        return first
    }

    /// The segments the planner meant: those under one of its points, or else those that fit its box best.
    static func meant(_ segments: [Segment], points: [NormalizedPoint], box: NormalizedRect?) -> [Segment] {
        if !points.isEmpty {
            let under = segments.filter { segment in
                points.contains { point in
                    let size = segment.mask.size
                    let x = min(size.width - 1, max(0, Int(point.x * Double(size.width))))
                    let y = min(size.height - 1, max(0, Int(point.y * Double(size.height))))
                    return size.width > 0 && size.height > 0 && segment.mask[x, y] > 127
                }
            }
            // A point says exactly where; nothing under it means SAM missed that one, not that a neighbour will do.
            return under
        }
        guard let box else { return segments }
        let fits = segments.map { overlap($0.box, box) }
        let best = fits.max() ?? 0
        return best < 0.4 ? [] : zip(segments, fits).filter { $0.1 >= best * 0.6 }.map(\.0)
    }

    /// How much of a mask's coverage lies within another mask's bounding box, 0...1.
    static func share(of mask: MaskData, inside other: MaskData) -> Double {
        guard let box = other.boundingBox, mask.size.width > 0, mask.size.height > 0 else { return 0 }
        let left = Int(box.x * Double(mask.size.width)), right = Int(ceil((box.x + box.width) * Double(mask.size.width)))
        let top = Int(box.y * Double(mask.size.height)), bottom = Int(ceil((box.y + box.height) * Double(mask.size.height)))
        var total = 0.0, inside = 0.0
        for y in 0..<mask.size.height {
            for x in 0..<mask.size.width {
                let value = Double(mask[x, y])
                total += value
                if x >= left && x < right && y >= top && y < bottom { inside += value }
            }
        }
        return total > 0 ? inside / total : 0
    }

    /// A concept without colour words, for finding a thing after its colour changed; nil when nothing is left.
    static func withoutColour(_ concept: String) -> String? {
        let colours: Set<String> = ["white", "black", "grey", "gray", "red", "blue", "green", "yellow", "orange", "purple",
                                    "pink", "brown", "beige", "tan", "navy", "maroon", "dark", "light", "bright", "pale"]
        let words = concept.split(separator: " ").filter { !colours.contains($0.lowercased()) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Intersection over union of two rectangles.
    static func overlap(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let width = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let height = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let shared = width * height
        let union = a.width * a.height + b.width * b.height - shared
        return union > 0 ? shared / union : 0
    }

    /// Redraws a region as `prompt` describes, or takes it out when `prompt` is nil.
    private func redraw(_ region: Region, prompt: String?, label: String, kind: TraceEvent.Kind,
                        redraws: inout [String: Layer.ID], events: Events) async throws -> [String] {
        try await replaceRedraw(of: region.info.id, redraws: &redraws, events: events)
        let box = region.info.box
        // A removal is filled from what is around the thing, so it gets a crop three times its size; a redraw keeps
        // close to it, where its detail decides how well the new one fits.
        let margin = kind == .remove ? 1.0 : 0.15
        let expanded = NormalizedRect(x: box.x - box.width * margin, y: box.y - box.height * margin,
                                      width: box.width * (1 + 2 * margin), height: box.height * (1 + 2 * margin))
        guard let rect = expanded.onPhoto else { throw LumenError.invalidResponse("The region has no bounds.") }
        let image = try await host.render(region: rect, maxLongEdge: 2048)
        try checkCancellation()
        // The critic sees this region close up, as it was before this run first redrew it.
        if !closeUpsBefore.contains(where: { $0.region == region.info.id }) {
            let closeUp = try await host.render(region: rect, maxLongEdge: configuration.closeUpLongEdge)
            closeUpsBefore.append((region.info.id, rect, closeUp))
        }
        // SAM's edge sits right on the object, so a sliver of its old colour would ring the redrawn one; the redraw
        // shows a little past it, where the generator redrew the boundary too.
        let edge = max(2, Int((Double(min(image.size.width, image.size.height)) * 0.012).rounded()))
        // A removal reaches further, 6% of the crop's short side, and is softened outside the thing (below), or its
        // outer rim shows through the soft edge as a faint outline.
        let short = Double(min(image.size.width, image.size.height))
        let reach = kind == .remove ? max(edge, Int((short * 0.06).rounded())) : edge
        let original = region.mask.cropped(to: rect).resized(to: image.size)
        var mask = original.grown(by: reach)
        let text = Self.redrawPrompt(prompt, thing: region.info.concept ?? region.info.id, place: Self.place(of: box, in: rect),
                                     count: region.count)
        let request = GenerateRequest(image: image, mask: mask, prompt: text)
        // The redraw changes how the thing looks, so it is looked for without the old colour: a "white t-shirt"
        // redrawn blue is found as a "t-shirt". A removal is looked for as it was.
        let concept = kind == .regenerate ? region.info.concept.flatMap(Self.withoutColour) : region.info.concept
        var attempt = try await redrawAttempt(request, original: original, concept: concept,
                                              region: region.info.id, kind: kind, events: events)
        // A removal keeps its grown mask, to take all of the thing out, with an edge as soft as 1.5% of the crop
        // that blends what was drawn in its place into the photo; at 6% out, it ends well clear of the thing.
        if kind == .remove {
            let notes = try await removal(&attempt, request: request, original: original, concept: concept,
                                          region: region.info.id, events: events)
            return try await place(attempt.image, mask: mask.blurred(by: short * 0.015), rect: rect, label: label,
                                   region: region.info.id, kind: kind, notes: notes, redraws: &redraws, events: events)
        }
        var notes: [String] = []
        // What the check found mostly outside the region's box is something else, not this redraw moved or shrunk:
        // there is nothing to compare, so nothing to retry.
        if attempt.overlap != nil, let object = attempt.object, Self.share(of: object, inside: original) < 0.5 {
            notes.append("Could not check the redraw of \(region.info.id): what was found is elsewhere.")
            attempt.overlap = nil
            attempt.object = nil
        }
        if let overlap = attempt.overlap, overlap < 0.5 {
            do {
                let retry = try await redrawAttempt(request, original: original, concept: concept,
                                                    region: region.info.id, kind: kind, events: events)
                if let detail = retry.note { notes.append(detail) }
                if let nextOverlap = retry.overlap, nextOverlap > overlap { attempt = retry }
            } catch {
                let error = cancellationError(error)
                if error as? LumenError == .cancelled { throw error }
                notes.append("Could not retry the redraw of \(region.info.id): \(error.localizedDescription)")
            }
        }
        if let detail = attempt.note { notes.append(detail) }
        // A recolour shows exactly where the thing is: SAM's mask held to the photo's own edges, which keeps out a
        // border the generator drew past it (a dark line along a shirt onto a black backpack) while still taking in
        // the edge's last pixels. Then it takes in the rim or shade of the same colour SAM stopped short of, which the
        // redraw recoloured too: a teal fender's edge and its shaded underside, left teal beside the new red.
        mask = try await host.extended(try await host.fitted(original, region: rect), region: rect)
        if let overlap = attempt.overlap {
            if overlap >= 0.5, let object = attempt.object {
                mask = mask.union(object)
            } else {
                let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), overlap)
                notes.append("The redraw moved or resized the \(region.info.id) (overlap \(value)).")
            }
        }
        return try await place(attempt.image, mask: mask, rect: rect, label: label, region: region.info.id,
                               kind: kind, notes: notes, redraws: &redraws, events: events)
    }

    /// Restyles a person: redraws their face, head or body in a catalogue style, then grades the photo with the step's
    /// effect, or the style's own.
    private func restyle(_ step: StyleStep, run: inout Run, redraws: inout [String: Layer.ID], events: Events) async throws {
        let person = try step.region.map { try region($0) }
        let style = step.style.flatMap(PersonStyle.named)
        if let style, let person {
            let part = try await part(style.part, of: person, events: events)
            let label = "\(title(person.info.id)): \(style.title)"
            var notes: [String] = []
            var reshaped = false
            if let amount = style.reshape,
               let shaped = try await reshape(part, by: amount, style: style, label: label, redraws: &redraws, events: events) {
                notes += shaped
                reshaped = true
            }
            if style.redraws || !reshaped {
                notes += try await redraw(part, as: style, label: label, redraws: &redraws, events: events)
            }
            run.edit(person.info.id)
            run.done.append(label)
            run.done.append(contentsOf: notes)
        }
        guard let effect = (step.effect ?? style?.effect).flatMap(StyleEffect.named) else { return }
        // A style's own effect is part of it (the Gigachad meme is black and white), and says so for the critic.
        let ofStyle = step.effect == nil ? style.map { " (part of \($0.title))" } ?? "" : ""
        for part in effect.parts {
            let mask: AssetID?
            let name: String
            switch part.target {
            case .photo:
                (mask, name) = (nil, "Photo")
            case .person:
                guard let person else { continue }
                (mask, name) = (person.asset, title(person.info.id))
            case .background:
                guard let person else { continue }
                (mask, name) = (await assets.put(.mask(person.mask.inverted())), "Behind \(person.info.id)")
            }
            let label = "\(name): \(effect.title)\(ofStyle)"
            // A style redrawn again (the critic asking for more) keeps the grade it already has, not a second one.
            guard !layers.contains(where: { $0.info.label == label }) else { continue }
            try await apply(Layer(label: label, content: .adjustment(values: part.values, mask: mask)), kind: "style",
                            region: part.target == .photo ? nil : person?.info.id, events: events)
            run.done.append(label)
        }
    }

    /// What a style redraws of a person: the person for a body; otherwise their face or head, the largest one SAM finds
    /// that lies mostly on them, so in a group it is never the face beside theirs.
    private func part(_ part: PersonStyle.Part, of person: Region, events: Events) async throws -> Region {
        if part == .body || person.info.concept?.lowercased().contains(part.concept) == true { return person }
        let id = "\(person.info.id)-\(part.rawValue)"
        let image = try await host.render(maxLongEdge: configuration.selectionLongEdge)
        let request = SegmentRequest(image: image, concept: part.concept)
        let found = try await call(.select, model: segmenter.modelID, detail: "Find the \(part.rawValue) of \(person.info.id)", events: events) {
            try await self.segmenter.segment(request)
        }
        let theirs = found.map { $0.mask.resized(to: person.mask.size) }
            .filter { Self.share(of: $0, inside: person.mask) >= 0.5 }
            .max { $0.area < $1.area }
        guard let theirs, let region = try await region(Selection(id: id, concept: part.concept), mask: theirs,
                                                        label: part.concept, events: events) else {
            throw LumenError.invalidResponse("No \(part.rawValue) was found on the \(person.info.id).")
        }
        regions[id] = region
        return region
    }

    /// Redraws a person's face, head or body in a style. Unlike a recolour, its outline may change (a squarer jaw, a
    /// slimmer waist), so the redraw shows through the part's mask grown well past it and softened, as a removal's is,
    /// not held to the old edge. How far the outline moved is measured: a change too slight to see or too far to believe
    /// is asked for once more, and the critic is told the numbers.
    private func redraw(_ region: Region, as style: PersonStyle, label: String, redraws: inout [String: Layer.ID],
                        events: Events) async throws -> [String] {
        try await replaceRedraw(of: region.info.id, redraws: &redraws, events: events)
        let box = region.info.box
        // Room around the part for its outline to grow into: broader shoulders, a wider jaw.
        let margin = style.part == .body ? 0.25 : 0.3
        let expanded = NormalizedRect(x: box.x - box.width * margin, y: box.y - box.height * margin,
                                      width: box.width * (1 + 2 * margin), height: box.height * (1 + 2 * margin))
        guard let rect = expanded.onPhoto else { throw LumenError.invalidResponse("The region has no bounds.") }
        let image = try await host.render(region: rect, maxLongEdge: 2048)
        try checkCancellation()
        if !closeUpsBefore.contains(where: { $0.region == region.info.id }) {
            let closeUp = try await host.render(region: rect, maxLongEdge: configuration.closeUpLongEdge)
            closeUpsBefore.append((region.info.id, rect, closeUp))
        }
        let short = Double(min(image.size.width, image.size.height))
        let original = region.mask.cropped(to: rect).resized(to: image.size)
        // A body's reaches 8% of the crop past it, for broader shoulders; a face's 5%, for a wider jaw or a beard: further,
        // a head the redraw drew a little to one side showed twice through the soft edge, as a pale arc.
        let mask = original.grown(by: max(2, Int((short * (style.part == .body ? 0.08 : 0.05)).rounded())))
        let position = Self.place(of: box, in: rect)
        func attempt(_ firmness: PersonStyle.Firmness) async throws -> RedrawAttempt {
            let request = GenerateRequest(image: image, mask: mask, prompt: style.prompt(person: "person", place: position, firmer: firmness))
            return try await redrawAttempt(request, original: original, concept: style.part.concept, region: region.info.id,
                                           kind: .style, events: events)
        }
        var best = try await attempt(.asked)
        var notes: [String] = []
        /// Another attempt, or nil and why there is none.
        func retried(_ firmness: PersonStyle.Firmness) async throws -> (attempt: RedrawAttempt?, note: String?) {
            do {
                return (try await attempt(firmness), nil)
            } catch {
                let error = cancellationError(error)
                if error as? LumenError == .cancelled { throw error }
                return (nil, "Could not retry the \(style.title.lowercased()) of \(region.info.id): \(error.localizedDescription)")
            }
        }
        // Found again well off where they were, the person was replaced or moved: once more, keeping the closer.
        if let overlap = best.overlap, overlap < Self.samePerson {
            let retry = try await retried(.asked)
            if let note = retry.note { notes.append(note) }
            if let next = retry.attempt, (next.overlap ?? 0) > overlap { best = next }
        }
        if let limits = style.limits {
            func measured(_ attempt: RedrawAttempt) -> [(name: String, change: Double)]? {
                attempt.object.flatMap { ShapeMeasure.change(style.part, before: original, after: $0) }
            }
            if let changes = measured(best), Self.miss(changes, limits) > 0 {
                let largest = changes.map { abs($0.change) }.max() ?? 0
                let retry = try await retried(largest > limits.most ? .subtler : .stronger)
                if let note = retry.note { notes.append(note) }
                if let next = retry.attempt, let nextChanges = measured(next),
                   Self.miss(nextChanges, limits) < Self.miss(changes, limits), (next.overlap ?? 0) >= Self.samePerson {
                    best = next
                }
            }
            if let changes = measured(best) { notes.append(Self.shapeNote(changes, limits: limits)) }
        }
        // A face redrawn warmer or cooler than the photo around it shows a seam where the redraw ends, down the neck:
        // Muse Image "corrected" a bluish phone photo's skin, and did again when told not to. The host gives the redraw
        // back the photo's own cast where it can; otherwise a drifted one is drawn once more, told so, and the closer kept.
        if style.keepsTone, let matched = try await host.toneMatched(best.image, to: image, under: original) {
            best.image = matched
        } else if style.keepsTone, let drift = try await toneDrift(from: image, to: best.image, under: original), drift > Self.toneDrift {
            let retry = try await retried(.sameTone)
            if let note = retry.note { notes.append(note) }
            if let next = retry.attempt, (next.overlap ?? 0) >= Self.samePerson,
               let nextDrift = try await toneDrift(from: image, to: next.image, under: original), nextDrift < drift {
                best = next
            }
        }
        if let detail = best.note { notes.append(detail) }
        if let overlap = best.overlap, overlap < Self.samePerson {
            let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), overlap)
            notes.append("The \(region.info.id) was found well off where it was after the restyle (overlap \(value)).")
        }
        // Softened past the part, like a removal's, so the new outline and the background beside it blend in.
        return try await place(best.image, mask: mask.blurred(by: short * (style.part == .body ? 0.015 : 0.01)), rect: rect, label: label,
                               region: region.info.id, kind: .style, notes: notes, redraws: &redraws, events: events)
    }

    /// Reshapes a body by moving its pixels (`EditHost.reshaped`), by exactly the style's amount; nil when the host can't,
    /// for the image model to try instead. Only the pixels the warp moved are placed.
    private func reshape(_ region: Region, by amount: PersonStyle.Reshape, style: PersonStyle, label: String,
                         redraws: inout [String: Layer.ID], events: Events) async throws -> [String]? {
        // Its own layer, apart from a redraw of the same person, so one never replaces the other.
        let key = "\(region.info.id)-shape"
        try await replaceRedraw(of: key, redraws: &redraws, events: events)
        let box = region.info.box
        let expanded = NormalizedRect(x: box.x - box.width * 0.25, y: box.y - box.height * 0.25,
                                      width: box.width * 1.5, height: box.height * 1.5)
        guard let rect = expanded.onPhoto else { throw LumenError.invalidResponse("The region has no bounds.") }
        let image = try await host.render(region: rect, maxLongEdge: 2048)
        try checkCancellation()
        let started = Date()
        let original = region.mask.cropped(to: rect).resized(to: image.size)
        guard let shaped = try await host.reshaped(image, mask: original, shoulders: amount.shoulders, waist: amount.waist) else {
            return nil
        }
        try checkCancellation()
        events.yield(.trace(TraceEvent(kind: .style, detail: "Reshape \(region.info.id)", started: started,
                                       duration: max(0, Date().timeIntervalSince(started)))))
        if !closeUpsBefore.contains(where: { $0.region == region.info.id }) {
            let closeUp = try await host.render(region: rect, maxLongEdge: configuration.closeUpLongEdge)
            closeUpsBefore.append((region.info.id, rect, closeUp))
        }
        let changes = [("shoulders", amount.shoulders), ("waist", amount.waist)].map { (name: $0.0, change: $0.1) }
        let note = style.limits.map { Self.shapeNote(changes, limits: $0) } ?? ""
        return try await place(shaped.image, mask: shaped.changed.grown(by: 1).blurred(by: 1), rect: rect, label: label,
                               region: key, kind: .style, notes: [note].filter { !$0.isEmpty }, redraws: &redraws, events: events)
    }

    /// How far the colour under `mask` moved from `before` to `after` (CIELAB ΔE of their medians); nil when the host
    /// can't measure.
    private func toneDrift(from before: EncodedImage, to after: EncodedImage, under mask: MaskData) async throws -> Double? {
        guard let was = try await host.measure(before, mask: mask), let now = try await host.measure(after, mask: mask) else { return nil }
        return ((was.lightness - now.lightness) * (was.lightness - now.lightness) + (was.a - now.a) * (was.a - now.a)
                + (was.b - now.b) * (was.b - now.b)).squareRoot()
    }

    /// The colour drift past which a restyled face is redrawn: a seam of it shows down the neck.
    static let toneDrift = 8.0

    /// How much a restyled person found again must overlap where they were to be the same person, in the same place.
    static let samePerson = 0.6

    /// How far the largest change of an outline falls outside a style's limits; zero within them.
    static func miss(_ changes: [(name: String, change: Double)], _ limits: ShapeLimits) -> Double {
        let largest = changes.map { abs($0.change) }.max() ?? 0
        return max(0, limits.least - largest) + max(0, largest - limits.most)
    }

    /// The outline's change in words, for the critic: "Shape: shoulders +6%, waist −5% (a believable change is 2% to 12%)."
    static func shapeNote(_ changes: [(name: String, change: Double)], limits: ShapeLimits) -> String {
        func percent(_ value: Double) -> String {
            let rounded = Int((value * 100).rounded())
            return rounded < 0 ? "−\(-rounded)%" : "+\(rounded)%"
        }
        let measured = changes.map { "\($0.name) \(percent($0.change))" }.joined(separator: ", ")
        let least = Int((limits.least * 100).rounded()), most = Int((limits.most * 100).rounded())
        return "Shape: \(measured) (a believable change is \(least > 0 ? "\(least)% to " : "up to ")\(most)%)."
    }

    /// SAM looks for a removed thing again where it was. Still found there, it gets one more try, and the attempt
    /// that left less of it is kept.
    private func removal(_ attempt: inout RedrawAttempt, request: GenerateRequest, original: MaskData, concept: String?,
                         region: String, events: Events) async throws -> [String] {
        var notes: [String] = []
        if let left = attempt.overlap, left >= Self.stillThere {
            do {
                let retry = try await redrawAttempt(request, original: original, concept: concept,
                                                    region: region, kind: .remove, events: events)
                if let detail = retry.note { notes.append(detail) }
                if let next = retry.overlap, next < left { attempt = retry }
            } catch {
                let error = cancellationError(error)
                if error as? LumenError == .cancelled { throw error }
                notes.append("Could not retry the removal of \(region): \(error.localizedDescription)")
            }
        }
        if let detail = attempt.note { notes.append(detail) }
        if let left = attempt.overlap, left >= Self.stillThere {
            let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), left)
            notes.append("The \(region) is still found where it was after its removal (overlap \(value)).")
        }
        return notes
    }

    /// How much a removed thing found again may overlap where it was before it counts as still there.
    static let stillThere = 0.3

    /// Puts a redrawn crop on the photo as a layer.
    private func place(_ generated: EncodedImage, mask: MaskData, rect: NormalizedRect, label: String, region: String,
                       kind: TraceEvent.Kind, notes: [String], redraws: inout [String: Layer.ID], events: Events) async throws -> [String] {
        for detail in notes { note(kind, detail, events: events) }
        let imageAsset = await assets.put(.image(generated))
        let maskAsset = await assets.put(.mask(mask.resized(to: generated.size)))
        do {
            let layer = Layer(label: label, content: .patch(image: imageAsset, mask: maskAsset, rect: rect))
            try await apply(layer, kind: kind.rawValue, region: region, events: events)
            redraws[region] = layer.id
        } catch {
            await assets.remove(imageAsset)
            await assets.remove(maskAsset)
            throw error
        }
        return notes
    }

    /// What Muse Image is asked. It sees only the crop, so the prompt says which thing in it to change and where.
    /// Several things (`count` over 1) are named as every one of them, with no single place: told to change "the flower
    /// in the centre", Muse Image changed one of seven.
    static func redrawPrompt(_ prompt: String?, thing: String, place: String, count: Int = 1) -> String {
        let several = count > 1
        let things = thing.hasSuffix("s") ? thing : thing + "s"
        guard let prompt else {
            if several {
                return "Remove all \(count) \(things) in this picture, every part of each. Fill their places with what is "
                    + "behind them, continuing the surroundings naturally. Change nothing else."
            }
            return "Remove the whole \(thing) \(place) of this picture, every part of it. Fill its place with what is "
                + "behind it, continuing the surroundings naturally. Change nothing else."
        }
        let sentence = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = sentence.last.map { ".!?".contains($0) } ?? true ? sentence : sentence + "."
        if several {
            return "\(ended) This is for all \(count) of these \(things) in the picture: change every one of them fully, and nothing else."
        }
        return "\(ended) Change only the \(thing) \(place) of this picture, and nothing else."
    }

    /// Where `box` sits in `rect`, in words: "in the centre", "on the left", "at the top right".
    static func place(of box: NormalizedRect, in rect: NormalizedRect) -> String {
        let x = rect.width > 0 ? (box.x + box.width / 2 - rect.x) / rect.width : 0.5
        let y = rect.height > 0 ? (box.y + box.height / 2 - rect.y) / rect.height : 0.5
        let column = x < 1.0 / 3 ? "left" : x > 2.0 / 3 ? "right" : nil
        let row = y < 1.0 / 3 ? "top" : y > 2.0 / 3 ? "bottom" : nil
        switch (row, column) {
        case (nil, nil): return "in the centre"
        case (nil, let column?): return "on the \(column)"
        case (let row?, nil): return "at the \(row)"
        case (let row?, let column?): return "at the \(row) \(column)"
        }
    }

    private struct RedrawAttempt {
        var image: EncodedImage
        var object: MaskData?
        var overlap: Double?
        var note: String?
    }

    private func redrawAttempt(_ request: GenerateRequest, original: MaskData, concept: String?, region: String,
                               kind: TraceEvent.Kind, events: Events) async throws -> RedrawAttempt {
        let image = try await call(kind, model: generator.modelID, detail: request.prompt, events: events) {
            try await self.generator.generate(request)
        }
        guard let concept else { return RedrawAttempt(image: image) }
        let removed = kind == .remove
        do {
            let request = SegmentRequest(image: image, concept: concept)
            let segments = try await call(.select, model: segmenter.modelID,
                                          detail: "Check the \(removed ? "removal" : "redraw") of \(region)", events: events) {
                try await self.segmenter.segment(request)
            }
            let matches = segments.map { segment in
                let mask = segment.mask.resized(to: original.size)
                return (mask: mask, overlap: original.intersectionOverUnion(mask))
            }.filter { $0.mask.boundingBox != nil }
            // Several things redrawn together (the flowers, the sails) are compared all together, not one by one.
            var candidates = matches
            if matches.count > 1, let first = matches.first?.mask {
                let union = matches.dropFirst().reduce(first) { $0.union($1.mask) }
                candidates.append((mask: union, overlap: original.intersectionOverUnion(union)))
            }
            guard let best = candidates.max(by: { $0.overlap < $1.overlap }) else {
                // Nothing found is what a removal is for.
                if removed { return RedrawAttempt(image: image, overlap: 0) }
                return RedrawAttempt(image: image, note: "Could not check the redraw of \(region): nothing found for “\(concept)”.")
            }
            return RedrawAttempt(image: image, object: best.mask, overlap: best.overlap)
        } catch {
            let error = cancellationError(error)
            if error as? LumenError == .cancelled { throw error }
            return RedrawAttempt(image: image, note: "Could not check the \(removed ? "removal" : "redraw") of \(region): \(error.localizedDescription)")
        }
    }

    private func replaceRedraw(of region: String, redraws: inout [String: Layer.ID], events: Events) async throws {
        guard let id = redraws[region], let layer = layers.first(where: { $0.id == id }) else { return }
        let started = Date()
        try await host.remove(id)
        layers.removeAll { $0.id == id }
        redraws[region] = nil
        events.yield(.reverted(id))
        events.yield(.trace(TraceEvent(kind: .revert, detail: "Reverted \(layer.info.label) (\(layer.info.id))",
                                       started: started, duration: max(0, Date().timeIntervalSince(started)))))
        try checkCancellation()
    }

    private func apply(_ layer: Layer, kind: String, region: String? = nil, events: Events) async throws {
        try checkCancellation()
        do {
            try await host.apply(layer, assets: assets)
            try checkCancellation()
        } catch {
            try? await host.remove(layer.id)
            throw error
        }
        layers.append(AppliedLayer(id: layer.id, info: LayerInfo(id: layer.id.uuidString, label: layer.label,
                                                               kind: kind, region: region)))
        events.yield(.applied(layer))
    }

    private func region(_ id: String) throws -> Region {
        guard let region = regions[id] else { throw LumenError.unknownRegion(id) }
        return region
    }

    private func call<Value: Sendable>(_ kind: TraceEvent.Kind, model: String, detail: String, events: Events,
                                       operation: @Sendable () async throws -> Value) async throws -> Value {
        try checkCancellation()
        let started = Date()
        let usage = ModelUsageRecorder()
        let notes = ModelCallNoteRecorder()
        do {
            let value = try await ModelUsageReporting.$report.withValue(usage.record) {
                try await ModelCallNotes.$report.withValue(notes.record) { try await operation() }
            }
            try checkCancellation()
            events.yield(.trace(TraceEvent(kind: kind, model: model, detail: notes.detail(short(detail)), started: started,
                                           duration: max(0, Date().timeIntervalSince(started))).recording(usage.value)))
            return value
        } catch {
            let error = cancellationError(error)
            events.yield(.trace(TraceEvent(kind: kind, model: model, detail: notes.detail(short("\(detail): \(error.localizedDescription)")),
                                           started: started, duration: max(0, Date().timeIntervalSince(started))).recording(usage.value)))
            throw error
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw LumenError.cancelled }
    }

    private func cancellationError(_ error: any Error) -> any Error {
        Task.isCancelled || error is CancellationError ? LumenError.cancelled : error
    }

    private func note(_ kind: TraceEvent.Kind, _ detail: String, events: Events) {
        events.yield(.trace(TraceEvent(kind: kind, detail: detail, started: Date(), duration: 0)))
    }

    private func finish(_ reason: String, events: Events) {
        note(.finish, reason, events: events)
        events.yield(.finished(reason: reason))
        events.finish()
    }

    private func title(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }

    private func short(_ detail: String) -> String {
        detail.count > 160 ? String(detail.prefix(159)) + "…" : detail
    }
}

private extension EditStep {
    var region: String? {
        switch self {
        case .adjust(let step): step.region
        case .regenerate(let step): step.region
        case .remove(let step): step.region
        case .style(let step): step.region
        default: nil
        }
    }
}
