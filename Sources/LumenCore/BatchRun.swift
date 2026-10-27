import Foundation

/// Holds the decisions and results of one library edit.
actor BatchRun {
    private let host: any LibraryHost
    private let reviewer: (any BatchPlanner)?
    private let planner: any Planner
    private let segmenter: any Segmenter
    private let generator: any Generator
    private let configuration: AgentConfiguration
    private let options: BatchOptions
    private let events: AsyncThrowingStream<BatchEvent, Error>.Continuation
    private let calls: BatchCalls
    private var photos: [PhotoID] = []
    private var facts: [PhotoID: PhotoFacts] = [:]
    private var reviews: [PhotoID: PhotoReview] = [:]
    private var results: [PhotoID: BatchPhotoResult] = [:]
    private var changed: Set<PhotoID> = []
    private var completed: Set<PhotoID> = []
    private var agents: [PhotoID: EditAgent] = [:]
    private var earlyAnswers: [String: String]
    private var answers: [BatchAnswer] = []
    private var waitingQuestions: [String: BatchQuestion] = [:]
    private var questionWaiters: [String: CheckedContinuation<String, Error>] = [:]
    private var approved: Bool
    private var approvalWaiter: CheckedContinuation<Void, Error>?
    private var cancelled = false

    private let closerLook = "Improve this photo naturally: fix exposure, colour and contrast where they are off, and nothing else."

    init(host: any LibraryHost, reviewer: (any BatchPlanner)?, planner: any Planner, segmenter: any Segmenter,
         generator: any Generator, configuration: AgentConfiguration, options: BatchOptions,
         events: AsyncThrowingStream<BatchEvent, Error>.Continuation, answers: [String: String], approved: Bool) {
        self.host = host
        self.reviewer = reviewer
        self.planner = planner
        self.segmenter = segmenter
        self.generator = generator
        self.configuration = configuration
        self.options = options
        self.events = events
        self.calls = BatchCalls(limit: options.maxModelCalls)
        self.earlyAnswers = answers
        self.approved = approved
    }

    func execute(onFinish: @Sendable () async -> Void) async {
        let started = Date()
        do {
            try checkCancellation()
            let found = try await host.photos()
            try checkCancellation()
            var seen: Set<PhotoID> = []
            photos = found.filter { seen.insert($0).inserted }
            results = Dictionary(uniqueKeysWithValues: photos.map { ($0, BatchPhotoResult(photo: $0)) })
            events.yield(.found(count: photos.count))
            try await batchForEach(photos, limit: options.concurrency) { try await self.measure($0) }
            try await review()
            let kept = photos.filter { results[$0]?.failed == false && reviews[$0] != nil && !isMisfire($0) }
            var plan: BatchPlan
            if options.mode == .planFirst {
                let straighten = try await decideStraightening(kept)
                plan = try await instructionPlan(kept)
                let estimate = estimate(plan, kept: kept, straighten: straighten)
                events.yield(.awaitingApproval(plan, estimatedModelCalls: estimate))
                try await waitForApproval()
                try await flagMisfires()
                try await basePass(kept, straighten: straighten)
                try await closerLook(kept)
            } else {
                try await flagMisfires()
                try await applyAuto(kept)
                let straighten = try await decideStraightening(kept.filter { results[$0]?.failed == false })
                try await straightenPhotos(kept, enabled: straighten)
                try await closerLook(kept)
                plan = try await instructionPlan(kept.filter { results[$0]?.failed == false })
            }
            for group in plan.groups {
                guard let instruction = group.instruction else { continue }
                try await batchForEach(group.photos, limit: options.concurrency) { photo in
                    try await self.edit(photo, instruction: instruction)
                }
            }
            try await batchForEach(kept, limit: options.concurrency) { try await self.save($0) }
            try checkCancellation()
            for photo in photos {
                if reviews[photo] == nil, results[photo]?.failed == false {
                    results[photo]?.outcome = "Skipped: model call limit reached."
                }
                complete(photo)
            }
            let summary = BatchSummary(photos: photos.compactMap { results[$0] }, answers: answers,
                                       modelCalls: await calls.count, duration: max(0, Date().timeIntervalSince(started)))
            try checkCancellation()
            await onFinish()
            try checkCancellation()
            events.yield(.finished(summary))
            events.finish()
        } catch {
            await onFinish()
            events.finish(throwing: isCancellation(error) ? LumenError.cancelled : error)
        }
    }

    func answer(_ id: String, with answer: String) {
        guard !cancelled else { return }
        if let question = waitingQuestions[id] {
            guard question.options.contains(answer) else { return }
            questionWaiters.removeValue(forKey: id)?.resume(returning: answer)
            waitingQuestions[id] = nil
        } else {
            // Unasked ids have no effect unless a later plan actually asks that question.
            earlyAnswers[id] = answer
        }
    }

    func approve() {
        guard !cancelled else { return }
        approved = true
        approvalWaiter?.resume()
        approvalWaiter = nil
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        for waiter in questionWaiters.values { waiter.resume(throwing: LumenError.cancelled) }
        questionWaiters.removeAll()
        waitingQuestions.removeAll()
        approvalWaiter?.resume(throwing: LumenError.cancelled)
        approvalWaiter = nil
        events.finish(throwing: LumenError.cancelled)
        for agent in agents.values { await agent.cancel() }
    }

    private func measure(_ photo: PhotoID) async throws {
        do {
            try checkCancellation()
            let measured = try await host.facts(photo)
            try checkCancellation()
            facts[photo] = measured
            events.yield(.measured(photo, measured))
        } catch {
            try record(error, for: photo)
        }
    }

    private func review() async throws {
        let measured = photos.filter { facts[$0] != nil }
        guard let reviewer else {
            for photo in measured {
                try checkCancellation()
                guard let facts = facts[photo] else { continue }
                let review = measuredReview(photo, facts: facts)
                reviews[photo] = review
                events.yield(.reviewed(review))
            }
            return
        }
        let batches = stride(from: 0, to: measured.count, by: 20).map { start in
            Array(measured[start..<min(start + 20, measured.count)])
        }
        try await batchForEach(batches, limit: min(3, max(1, options.concurrency))) { batch in
            try await self.review(batch, with: reviewer)
        }
    }

    private func review(_ batch: [PhotoID], with reviewer: any BatchPlanner) async throws {
        var inputs: [ReviewPhoto] = []
        for photo in batch {
            do {
                try checkCancellation()
                let thumbnail = try await host.thumbnail(photo, maxLongEdge: 512)
                try checkCancellation()
                if let facts = facts[photo] { inputs.append(ReviewPhoto(photo: photo, thumbnail: thumbnail, facts: facts)) }
            } catch {
                try record(error, for: photo)
            }
        }
        guard !inputs.isEmpty else { return }
        do {
            let request = ReviewRequest(instruction: options.instruction, photos: inputs)
            let response = try await call(.critique, model: reviewer.modelID, detail: "Review \(inputs.count) photos") {
                try await reviewer.review(request)
            }
            for input in inputs {
                let matches = response.filter { $0.photo == input.photo }
                guard matches.count == 1, let review = matches.first, review.quality.isFinite,
                      (0...1).contains(review.quality) else {
                    try record(LumenError.invalidResponse("Expected one review with a quality from 0 to 1."), for: input.photo)
                    continue
                }
                reviews[input.photo] = review
                events.yield(.reviewed(review))
            }
        } catch is BatchCallLimit {
            return
        } catch {
            for input in inputs { try record(error, for: input.photo) }
        }
    }

    /// Measurement-only quality averages detail, balanced exposure and unclipped coverage.
    private func measuredReview(_ photo: PhotoID, facts: PhotoFacts) -> PhotoReview {
        func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        let quality = (unit(facts.sharpness) + unit(1 - abs(2 * facts.exposure - 1))
                       + unit(1 - facts.clippedShadows - facts.clippedHighlights)) / 3
        let reason: String?
        if facts.sharpness < 0.05 {
            reason = "Almost no fine detail was measured."
        } else if facts.exposure < 0.03 {
            reason = "The photo is almost black."
        } else if facts.exposure > 0.97 {
            reason = "The photo is almost white."
        } else {
            reason = nil
        }
        return PhotoReview(photo: photo, misfire: reason != nil, misfireReason: reason, quality: quality,
                           description: "Measured photo", group: photo.rawValue, matchesInstruction: true)
    }

    private func isMisfire(_ photo: PhotoID) -> Bool {
        options.flagMisfires && reviews[photo]?.misfire == true
    }

    private func flagMisfires() async throws {
        guard options.flagMisfires else { return }
        for photo in photos where isMisfire(photo) {
            let reason = reviews[photo]?.misfireReason ?? "The shot misfired."
            do {
                try checkCancellation()
                try await host.flag(photo, reason: reason)
                try checkCancellation()
                results[photo]?.flagged = reason
                events.yield(.flagged(photo, reason: reason))
            } catch {
                try record(error, for: photo)
            }
            complete(photo)
        }
    }

    private func basePass(_ kept: [PhotoID], straighten: Bool) async throws {
        try await applyAuto(kept)
        try await straightenPhotos(kept, enabled: straighten)
    }

    private func applyAuto(_ kept: [PhotoID]) async throws {
        guard options.auto else { return }
        try await batchForEach(kept, limit: options.concurrency) { photo in
            try await self.auto(photo)
        }
    }

    private func auto(_ photo: PhotoID) async throws {
        guard results[photo]?.failed == false else { return }
        do {
            try checkCancellation()
            let label = try await host.applyAuto(photo)
            try checkCancellation()
            results[photo]?.auto = label
            changed.insert(photo)
            events.yield(.autoApplied(photo, label: label))
        } catch {
            try record(error, for: photo)
        }
    }

    private func tilted(_ kept: [PhotoID]) -> [PhotoID] {
        kept.filter { photo in
            // A measured tilt counts when the reviewer, looking at the photo, does not say it is level, and it is
            // small enough to be an accident: past 6° a tilt is usually meant.
            guard let tilt = facts[photo]?.tilt, tilt.isFinite, reviews[photo]?.tilted != false else { return false }
            return abs(tilt) >= 0.5 && abs(tilt) <= 6
        }
    }

    private func decideStraightening(_ kept: [PhotoID]) async throws -> Bool {
        if let straighten = options.straighten { return straighten }
        let tilted = tilted(kept)
        guard !tilted.isEmpty else { return false }
        let tilts = tilted.compactMap { facts[$0]?.tilt }.map(abs)
        let maximum = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tilts.max() ?? 0)
        let recommended = tilts.filter { $0 >= 1 }.count > tilts.count / 2 ? 0 : 1
        let question = BatchQuestion(id: "straighten", question: "\(tilted.count) photos look tilted, by up to \(maximum)°. Straighten them?",
                                     options: ["Straighten them", "Leave them"], recommended: recommended)
        return try await choose(question) == "Straighten them"
    }

    private func straightenPhotos(_ kept: [PhotoID], enabled: Bool) async throws {
        guard enabled else { return }
        try await batchForEach(tilted(kept), limit: options.concurrency) { photo in
            try await self.straighten(photo)
        }
    }

    private func straighten(_ photo: PhotoID) async throws {
        guard results[photo]?.failed == false, let tilt = facts[photo]?.tilt else { return }
        do {
            try checkCancellation()
            try await host.straighten(photo, degrees: -tilt)
            try checkCancellation()
            results[photo]?.straightened = -tilt
            changed.insert(photo)
            events.yield(.straightened(photo, degrees: -tilt))
        } catch {
            try record(error, for: photo)
        }
    }

    private func closerLook(_ kept: [PhotoID]) async throws {
        let low = kept.filter { (reviews[$0]?.quality ?? 1) < options.qualityThreshold }
        try await batchForEach(low, limit: options.concurrency) { photo in
            try await self.edit(photo, instruction: self.closerLook)
        }
    }

    private func instructionPlan(_ kept: [PhotoID]) async throws -> BatchPlan {
        guard let instruction = options.instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let plan = basePlan(kept)
            events.yield(.planned(plan))
            return plan
        }
        guard let reviewer else {
            let plan = BatchPlan(summary: instruction, groups: [BatchGroup(id: "library", title: "Library", photos: kept, instruction: instruction)])
            events.yield(.planned(plan))
            return plan
        }
        let matching = kept.compactMap { reviews[$0] }.filter(\.matchesInstruction)
        guard !matching.isEmpty else {
            let plan = basePlan(kept)
            events.yield(.planned(plan))
            return plan
        }
        var latest = basePlan(kept)
        for round in 0..<3 {
            let request = BatchPlanRequest(instruction: instruction, reviews: matching,
                                           answers: Dictionary(uniqueKeysWithValues: answers.map { ($0.question.id, $0.answer) }))
            do {
                latest = try await call(.plan, model: reviewer.planModelID, detail: instruction) { try await reviewer.plan(request) }
            } catch is BatchCallLimit {
                for review in matching { note("Instruction skipped: model call limit reached.", for: review.photo) }
                latest = basePlan(kept)
                break
            }
            latest = checked(latest, kept: kept, matching: Set(matching.map(\.photo)))
            events.yield(.planned(latest))
            if latest.questions.isEmpty { return latest }
            for question in latest.questions { _ = try await choose(question, recommendationOnly: round == 2) }
        }
        latest.questions = []
        events.yield(.planned(latest))
        return latest
    }

    private func basePlan(_ kept: [PhotoID]) -> BatchPlan {
        BatchPlan(summary: "Apply the base pass and give low-quality photos a closer look.",
                  groups: [BatchGroup(id: "library", title: "Library", photos: kept, instruction: nil)])
    }

    private func checked(_ plan: BatchPlan, kept: [PhotoID], matching: Set<PhotoID>) -> BatchPlan {
        var plan = plan
        var seen: Set<PhotoID> = []
        plan.groups = plan.groups.compactMap { group in
            var group = group
            var inGroup: Set<PhotoID> = []
            group.photos = group.photos.filter { matching.contains($0) && inGroup.insert($0).inserted }
            seen.formUnion(group.photos)
            return group.photos.isEmpty ? nil : group
        }
        let other = kept.filter { !seen.contains($0) }
        if !other.isEmpty {
            var id = "base"
            while plan.groups.contains(where: { $0.id == id }) { id += "-base" }
            plan.groups.append(BatchGroup(id: id, title: "Base pass", photos: other, instruction: nil))
        }
        return plan
    }

    private func choose(_ question: BatchQuestion, recommendationOnly: Bool = false) async throws -> String {
        try checkCancellation()
        guard !question.options.isEmpty, question.options.indices.contains(question.recommended) else {
            throw LumenError.invalidResponse("A batch question needs options and a valid recommendation.")
        }
        if let previous = answers.first(where: { $0.question.id == question.id }), question.options.contains(previous.answer) {
            return previous.answer
        }
        let text: String
        let byPerson: Bool
        if options.mode == .autonomous || recommendationOnly {
            text = question.options[question.recommended]
            byPerson = false
        } else {
            events.yield(.question(question))
            if let early = earlyAnswers.removeValue(forKey: question.id), question.options.contains(early) {
                text = early
            } else {
                text = try await withCheckedThrowingContinuation { waiter in
                    waitingQuestions[question.id] = question
                    questionWaiters[question.id] = waiter
                }
            }
            byPerson = true
        }
        try checkCancellation()
        let answer = BatchAnswer(question: question, answer: text, byPerson: byPerson)
        answers.removeAll { $0.question.id == question.id }
        answers.append(answer)
        events.yield(.answered(answer))
        return text
    }

    private func waitForApproval() async throws {
        try checkCancellation()
        if !approved { try await withCheckedThrowingContinuation { approvalWaiter = $0 } }
        try checkCancellation()
    }

    private func estimate(_ plan: BatchPlan, kept: [PhotoID], straighten: Bool) -> Int {
        let instructed = Set(plan.groups.filter { $0.instruction != nil }.flatMap(\.photos))
        let edits = kept.filter { instructed.contains($0) || (reviews[$0]?.quality ?? 1) < options.qualityThreshold }.count
        return edits * 5 + (straighten ? tilted(kept).count : 0)
    }

    private func edit(_ photo: PhotoID, instruction: String) async throws {
        guard results[photo]?.failed == false else { return }
        try checkCancellation()
        guard let reservation = await calls.reserve(5) else {
            note("Edit skipped: model call limit reached.", for: photo)
            return
        }
        results[photo]?.instruction = instruction
        events.yield(.editStarted(photo, instruction: instruction))
        do {
            let editHost = try await host.editHost(photo)
            try checkCancellation()
            let agent = EditAgent(planner: BatchPhotoPlanner(base: planner, calls: calls, reservation: reservation),
                                  segmenter: BatchPhotoSegmenter(base: segmenter, calls: calls, reservation: reservation),
                                  generator: BatchPhotoGenerator(base: generator, calls: calls, reservation: reservation),
                                  host: editHost, configuration: configuration)
            agents[photo] = agent
            try await withTaskCancellationHandler {
                for try await event in agent.run(instruction) {
                    try checkCancellation()
                    if case .trace(let trace) = event {
                        let recorded = await calls.record(trace, reservation: reservation)
                        events.yield(.edit(photo, .trace(recorded)))
                    } else {
                        events.yield(.edit(photo, event))
                    }
                    switch event {
                    case .applied, .reverted:
                        changed.insert(photo)
                    case .finished(let reason):
                        note(reason, for: photo)
                    case .trace(let trace) where trace.kind == .failure:
                        results[photo]?.failed = true
                        note(trace.detail, for: photo)
                    default:
                        break
                    }
                }
                try checkCancellation()
            } onCancel: {
                Task { await agent.cancel() }
            }
        } catch is BatchCallLimit {
            note("Model call limit reached.", for: photo)
        } catch {
            if isCancellation(error) {
                await agents[photo]?.cancel()
                agents[photo] = nil
                await calls.release(reservation)
                throw LumenError.cancelled
            }
            try record(error, for: photo)
        }
        agents[photo] = nil
        await calls.release(reservation)
        if let result = results[photo] { events.yield(.editFinished(result)) }
    }

    private func save(_ photo: PhotoID) async throws {
        do {
            try checkCancellation()
            if changed.contains(photo) { try await host.save(photo) }
            try checkCancellation()
        } catch {
            try record(error, for: photo)
        }
        complete(photo)
    }

    private func call<Value: Sendable>(_ kind: TraceEvent.Kind, model: String, detail: String,
                                      operation: @Sendable () async throws -> Value) async throws -> Value {
        try checkCancellation()
        try await calls.begin()
        let started = Date()
        do {
            let value = try await operation()
            try checkCancellation()
            events.yield(.trace(TraceEvent(kind: kind, model: model, detail: detail, started: started,
                                           duration: max(0, Date().timeIntervalSince(started)))))
            return value
        } catch {
            events.yield(.trace(TraceEvent(kind: kind, model: model, detail: error.localizedDescription, started: started,
                                           duration: max(0, Date().timeIntervalSince(started)))))
            throw error
        }
    }

    private func note(_ text: String, for photo: PhotoID) {
        if let previous = results[photo]?.outcome { results[photo]?.outcome = previous + "\n" + text }
        else { results[photo]?.outcome = text }
    }

    private func record(_ error: any Error, for photo: PhotoID) throws {
        if isCancellation(error) { throw LumenError.cancelled }
        results[photo]?.failed = true
        note(error.localizedDescription, for: photo)
    }

    private func complete(_ photo: PhotoID) {
        if completed.insert(photo).inserted { events.yield(.progress(done: completed.count, total: photos.count)) }
    }

    private func checkCancellation() throws {
        if cancelled || Task.isCancelled { throw LumenError.cancelled }
    }

    private func isCancellation(_ error: any Error) -> Bool {
        cancelled || Task.isCancelled || error is CancellationError || error as? LumenError == .cancelled
    }
}
