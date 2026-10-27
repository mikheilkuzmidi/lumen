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
        case plan, select, adjust, regenerate, remove, crop, revert, critique, finish, failure
    }

    public var kind: Kind
    /// The model that answered, for model calls.
    public var model: String?
    public var detail: String
    public var started: Date
    public var duration: TimeInterval

    public init(kind: Kind, model: String? = nil, detail: String, started: Date, duration: TimeInterval) {
        self.kind = kind
        self.model = model
        self.detail = detail
        self.started = started
        self.duration = duration
    }
}

public struct AgentConfiguration: Sendable {
    /// Steps attempted for one instruction, across every revision.
    public var maxSteps = 12
    /// Times the planner may look at its result and revise it.
    public var maxRevisions = 2
    /// The long edge of the photo the planner and critic see.
    public var previewLongEdge = 1536

    public init(maxSteps: Int = 12, maxRevisions: Int = 2, previewLongEdge: Int = 1536) {
        self.maxSteps = maxSteps
        self.maxRevisions = maxRevisions
        self.previewLongEdge = previewLongEdge
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

    public init(planner: any Planner, segmenter: any Segmenter, generator: any Generator, host: any EditHost,
                configuration: AgentConfiguration = AgentConfiguration()) {
        self.planner = planner
        self.segmenter = segmenter
        self.generator = generator
        self.host = host
        self.configuration = configuration
    }

    /// Runs the instruction; `area` is where the user asked the agent to look.
    public nonisolated func run(_ instruction: String, area: NormalizedRect? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { events in
            let task = Task {
                await self.start(instruction, area: area, events: events)
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
    }

    private typealias Events = AsyncThrowingStream<AgentEvent, Error>.Continuation

    private func start(_ instruction: String, area: NormalizedRect?, events: Events) async {
        let id = UUID()
        let previous = latestRun
        let task = Task {
            await previous?.value
            await self.run(instruction, area: area, events: events)
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

    private func run(_ instruction: String, area: NormalizedRect?, events: Events) async {
        do {
            try checkCancellation()
            var run = Run()
            var redraws: [String: Layer.ID] = [:]
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
                let request = CritiqueRequest(instruction: instruction, before: before, after: after,
                                              regions: regionInfo, done: run.done, layers: layerInfo,
                                              history: Array(history.dropLast()))
                let critique = try await call(.critique, model: planner.modelID, detail: "Check the edit", events: events) {
                    try await self.planner.critique(request)
                }
                events.yield(.critiqued(critique))
                if critique.satisfied {
                    finish(critique.notes, events: events)
                    return
                }
                guard revisions < max(0, configuration.maxRevisions) else {
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
                    let region = try adjustment.region.map { try region($0) }
                    let settings = AdjustmentKey.allCases.compactMap { key -> String? in
                        guard let value = adjustment.values[key] else { return nil }
                        let name = key == .noiseReduction ? "noise reduction" : key.rawValue
                        let magnitude = String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), abs(value))
                        return "\(name) \(value < 0 ? "−" : "+")\(magnitude)"
                    }.joined(separator: ", ")
                    let label = "\(title(adjustment.region ?? "photo")): \(settings)"
                    let layer = Layer(label: label, content: .adjustment(values: adjustment.values, mask: region?.asset))
                    try await apply(layer, kind: step.type, region: adjustment.region, events: events)
                    run.done.append(label)
                case .regenerate(let regeneration):
                    needsLook = true
                    let label = "\(title(regeneration.region)): redrawn as \(regeneration.prompt)"
                    let notes = try await redraw(try region(regeneration.region), prompt: regeneration.prompt,
                                                 label: label, kind: .regenerate, redraws: &redraws, events: events)
                    run.done.append(label)
                    run.done.append(contentsOf: notes)
                    troubled = troubled || !notes.isEmpty
                case .remove(let removal):
                    needsLook = true
                    let label = "\(title(removal.region)): removed"
                    _ = try await redraw(try region(removal.region),
                                     prompt: "Remove the selected object and fill the area naturally from its surroundings",
                                     label: label, kind: .remove, redraws: &redraws, events: events)
                    run.done.append(label)
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
        let image = try await host.render(maxLongEdge: configuration.previewLongEdge)
        try checkCancellation()
        let request = SegmentRequest(image: image, concept: selection.concept,
                                     box: selection.box ?? area, points: selection.points)
        var segments = try await call(.select, model: segmenter.modelID,
                                      detail: "Find \(selection.concept ?? selection.id)", events: events) {
            try await self.segmenter.segment(request)
        }
        // When the planner says which one it means among several, keep only that: the segments under its points,
        // or else the ones that fit its box. If nothing fits (SAM found the neighbour's shirt but not this one),
        // nothing is kept, rather than the wrong one.
        if selection.concept != nil, !segments.isEmpty, selection.box != nil || !selection.points.isEmpty {
            segments = Self.meant(segments, points: selection.points, box: selection.box)
            if segments.isEmpty {
                note(.select, "What was found for \(selection.id) is not where the planner pointed.", events: events)
            }
        }
        // The planner's box is a guess; when it rules out everything, search the whole photo (or the user's area).
        // That is only trusted when it finds exactly one: with several, it cannot say which was meant.
        if segments.isEmpty, selection.box != nil, selection.concept != nil {
            note(.select, "Nothing found inside the planner's box for \(selection.id); looking again without it.", events: events)
            let wider = SegmentRequest(image: image, concept: selection.concept, box: area, points: selection.points)
            let found = try await call(.select, model: segmenter.modelID, detail: "Find \(selection.concept ?? selection.id) again", events: events) {
                try await self.segmenter.segment(wider)
            }
            if found.count == 1 { segments = found }
            else if found.count > 1 { note(.select, "Found \(found.count) of them elsewhere; none is the one meant.", events: events) }
        }
        if segments.isEmpty, let concept = selection.concept, request.box != nil || !request.points.isEmpty {
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
        if selection.invert { mask = mask.inverted() }
        guard let box = mask.boundingBox else {
            note(.select, "Nothing found for \(selection.id) after inversion.", events: events)
            return nil
        }
        try checkCancellation()
        let asset = await assets.put(.mask(mask))
        do { try checkCancellation() } catch {
            await assets.remove(asset)
            throw error
        }
        let segment = Segment(label: selection.concept ?? first.label, box: box, mask: mask,
                              score: segments.count == 1 ? first.score : nil)
        events.yield(.selected(region: selection.id, segment: segment))
        return Region(info: RegionInfo(id: selection.id, concept: selection.concept, box: box, area: mask.area),
                      mask: mask, asset: asset)
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

    private func redraw(_ region: Region, prompt: String, label: String, kind: TraceEvent.Kind,
                        redraws: inout [String: Layer.ID], events: Events) async throws -> [String] {
        try await replaceRedraw(of: region.info.id, redraws: &redraws, events: events)
        let box = region.info.box
        let expanded = NormalizedRect(x: box.x - box.width * 0.15, y: box.y - box.height * 0.15,
                                      width: box.width * 1.3, height: box.height * 1.3)
        guard let rect = expanded.onPhoto else { throw LumenError.invalidResponse("The region has no bounds.") }
        let image = try await host.render(region: rect, maxLongEdge: 2048)
        try checkCancellation()
        // SAM's edge sits right on the object, so a sliver of its old colour would ring the redrawn one; the redraw
        // shows a little past it, where the generator redrew the boundary too.
        let edge = max(2, Int((Double(min(image.size.width, image.size.height)) * 0.012).rounded()))
        let original = region.mask.cropped(to: rect).resized(to: image.size)
        var mask = original.grown(by: edge)
        let request = GenerateRequest(image: image, mask: mask, prompt: prompt)
        // The redraw changes how the thing looks, so it is looked for without the old colour: a "white t-shirt"
        // redrawn blue is found as a "t-shirt".
        let concept = kind == .regenerate ? region.info.concept.flatMap(Self.withoutColour) : nil
        var attempt = try await redrawAttempt(request, original: original, concept: concept,
                                              region: region.info.id, kind: kind, events: events)
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
        if let overlap = attempt.overlap {
            if overlap >= 0.5, let object = attempt.object {
                mask = mask.union(object.grown(by: edge))
            } else {
                let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), overlap)
                notes.append("The redraw moved or resized the \(region.info.id) (overlap \(value)).")
            }
        }
        for detail in notes { note(kind, detail, events: events) }
        let generated = attempt.image
        let imageAsset = await assets.put(.image(generated))
        let maskAsset = await assets.put(.mask(mask.resized(to: generated.size)))
        do {
            let layer = Layer(label: label, content: .patch(image: imageAsset, mask: maskAsset, rect: rect))
            try await apply(layer, kind: kind.rawValue, region: region.info.id, events: events)
            redraws[region.info.id] = layer.id
        } catch {
            await assets.remove(imageAsset)
            await assets.remove(maskAsset)
            throw error
        }
        return notes
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
        do {
            let request = SegmentRequest(image: image, concept: concept)
            let segments = try await call(.select, model: segmenter.modelID,
                                          detail: "Check the redraw of \(region)", events: events) {
                try await self.segmenter.segment(request)
            }
            let matches = segments.map { segment in
                let mask = segment.mask.resized(to: original.size)
                return (mask: mask, overlap: original.intersectionOverUnion(mask))
            }.filter { $0.mask.boundingBox != nil }
            guard let best = matches.max(by: { $0.overlap < $1.overlap }) else {
                return RedrawAttempt(image: image, note: "Could not check the redraw of \(region): nothing found for “\(concept)”.")
            }
            return RedrawAttempt(image: image, object: best.mask, overlap: best.overlap)
        } catch {
            let error = cancellationError(error)
            if error as? LumenError == .cancelled { throw error }
            return RedrawAttempt(image: image, note: "Could not check the redraw of \(region): \(error.localizedDescription)")
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
        do {
            let value = try await operation()
            try checkCancellation()
            events.yield(.trace(TraceEvent(kind: kind, model: model, detail: short(detail), started: started,
                                           duration: max(0, Date().timeIntervalSince(started)))))
            return value
        } catch {
            let error = cancellationError(error)
            events.yield(.trace(TraceEvent(kind: kind, model: model, detail: short("\(detail): \(error.localizedDescription)"),
                                           started: started, duration: max(0, Date().timeIntervalSince(started)))))
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
        default: nil
        }
    }
}
