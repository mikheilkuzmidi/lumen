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
    /// Only a successful content review can establish eligibility. Quality
    /// measurements and the text planner cannot add to this set.
    private var verifiedInstructionPhotos: Set<PhotoID> = []
    private var results: [PhotoID: BatchPhotoResult] = [:]
    private var changed: Set<PhotoID> = []
    private var completed: Set<PhotoID> = []
    private var agents: [PhotoID: EditAgent] = [:]
    private var earlyAnswers: [String: String]
    private var answers: [BatchAnswer] = []
    private var waitingQuestions: [String: BatchQuestion] = [:]
    private var questionWaiters: [String: CheckedContinuation<String, Error>] = [:]
    private var approved: Bool
    private var pendingPlan: BatchPlan?
    private var acceptedPlan: BatchPlan?
    private var excludedPhotos: Set<PhotoID> = []
    private var approvalWaiter: CheckedContinuation<BatchPlan, Error>?
    private var traces: [TraceEvent] = []
    private var cancelled = false
    private let started = Date()
    private var settledSnapshot: BatchSnapshot?

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

    func execute(onFinish: @Sendable (BatchSnapshot) async -> Void) async {
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
                plan = try await instructionPlan(kept, straighten: straighten)
                plan.approvalToken = UUID()
                plan.targetPhotos = photos
                plan.photoActions = plannedActions(kept, straighten: straighten)
                plan = estimated(plan, kept: kept)
                pendingPlan = plan
                events.yield(.awaitingApproval(plan, estimatedModelCalls: plan.estimatedModelCalls ?? 0))
                plan = try await waitForApproval()
                for photo in photos where excludedPhotos.contains(photo) {
                    note("Skipped: excluded from the approved plan.", for: photo)
                    complete(photo)
                }
                try await flagMisfires()
                try await basePass(kept, straighten: straighten)
                try await closerLook(kept)
            } else {
                try await flagMisfires()
                try await applyAuto(kept)
                let straighten = try await decideStraightening(kept.filter { results[$0]?.failed == false })
                try await straightenPhotos(kept, enabled: straighten)
                try await closerLook(kept)
                plan = try await instructionPlan(kept.filter { results[$0]?.failed == false }, straighten: straighten)
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
                                       modelCalls: await calls.count, duration: max(0, Date().timeIntervalSince(started)), events: traces)
            try checkCancellation()
            await onFinish(await snapshot(settled: true))
            try checkCancellation()
            events.yield(.finished(summary))
            events.finish()
        } catch {
            await onFinish(await snapshot(settled: true, cancelled: isCancellation(error)))
            events.finish(throwing: isCancellation(error) ? LumenError.cancelled : error)
        }
    }

    func snapshot(settled: Bool = false, cancelled requested: Bool = false) async -> BatchSnapshot {
        if let settledSnapshot { return settledSnapshot }
        var completedIDs: [PhotoID] = [], excludedIDs: [PhotoID] = [], flaggedIDs: [PhotoID] = []
        var failedIDs: [PhotoID] = [], skippedIDs: [PhotoID] = [], unfinishedIDs: [PhotoID] = []
        for photo in photos {
            if excludedPhotos.contains(photo) { excludedIDs.append(photo) }
            else if results[photo]?.failed == true { failedIDs.append(photo) }
            else if results[photo]?.flagged != nil { flaggedIDs.append(photo) }
            else if (results[photo]?.outcome?.split(separator: "\n").contains {
                $0.hasPrefix("Skipped:") || $0.hasPrefix("Edit skipped:") || $0.hasPrefix("Instruction skipped:") || $0 == "Model call limit reached."
            }) == true { skippedIDs.append(photo) }
            else if completed.contains(photo) { completedIDs.append(photo) }
            else { unfinishedIDs.append(photo) }
        }
        let summary = BatchSummary(photos: photos.compactMap { results[$0] }, answers: answers,
                                   modelCalls: await calls.count, duration: max(0, Date().timeIntervalSince(started)), events: traces)
        let snapshot = BatchSnapshot(summary: summary, completedPhotoIDs: completedIDs, excludedPhotoIDs: excludedIDs,
                                     flaggedPhotoIDs: flaggedIDs, failedPhotoIDs: failedIDs, skippedPhotoIDs: skippedIDs, unfinishedPhotoIDs: unfinishedIDs,
                                     cancelled: cancelled || requested || Task.isCancelled, settled: settled,
                                     startedModelCalls: await calls.attemptedCount)
        if settled { settledSnapshot = snapshot }
        return snapshot
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
        if let token = pendingPlan?.approvalToken {
            _ = try? approve(BatchApproval(approvalToken: token))
            return
        }
        approved = true
    }

    func previewApproval(_ approval: BatchApproval) throws -> BatchPlan {
        try checkCancellation()
        guard let plan = pendingPlan else { throw BatchApprovalError.noPendingPlan }
        guard plan.approvalToken == approval.approvalToken else { throw BatchApprovalError.staleToken }
        let targets = Set(photos)
        var excluded: Set<PhotoID> = []
        for photo in approval.excludedPhotoIDs {
            guard targets.contains(photo) else { throw BatchApprovalError.unknownPhoto(photo) }
            guard excluded.insert(photo).inserted else { throw BatchApprovalError.duplicateExcludedPhoto(photo) }
        }
        let groupIDs = Set(plan.groups.map(\.id))
        for (id, instruction) in approval.instructionOverrides {
            guard groupIDs.contains(id) else { throw BatchApprovalError.unknownGroup(id) }
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BatchApprovalError.emptyInstruction(id)
            }
        }
        var draft = plan
        draft.groups = try plan.groups.compactMap { group in
            var group = group
            group.photos.removeAll { excluded.contains($0) }
            if let instruction = approval.instructionOverrides[group.id] {
                group.instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if group.instruction != nil, reviewer != nil,
               !group.photos.allSatisfy({ verifiedInstructionPhotos.contains($0) }) {
                throw LumenError.invalidResponse("This group contains photos not visually verified for the requested edit. Run a new content review before adding an instruction.")
            }
            return group.photos.isEmpty ? nil : group
        }
        draft.photoActions = plan.photoActions?.filter { !excluded.contains($0.photo) }
        let kept = photos.filter { !excluded.contains($0) && results[$0]?.failed == false && reviews[$0] != nil && !isMisfire($0) }
        return estimated(draft, kept: kept, revisedInstructions: !approval.instructionOverrides.isEmpty)
    }

    func approve(_ approval: BatchApproval) throws -> BatchPlan {
        let draft = try previewApproval(approval)
        excludedPhotos = Set(approval.excludedPhotoIDs)
        pendingPlan = nil
        acceptedPlan = draft
        approved = true
        approvalWaiter?.resume(returning: draft)
        approvalWaiter = nil
        return draft
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        for waiter in questionWaiters.values { waiter.resume(throwing: LumenError.cancelled) }
        questionWaiters.removeAll()
        waitingQuestions.removeAll()
        pendingPlan = nil
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
            results[photo]?.measuredTilt = measured.tilt
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
                results[photo]?.levelLine = review.levelLine
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
            let response = try await call(.critique, model: reviewer.modelID, detail: "Review \(inputs.count) \(inputs.count == 1 ? "photo" : "photos")",
                                          phase: .reviewing(count: inputs.count, model: reviewer.modelID)) {
                try await reviewer.review(request)
            }
            for input in inputs {
                let matches = response.filter { $0.photo == input.photo }
                guard matches.count == 1, let review = matches.first, review.quality.isFinite,
                      (0...1).contains(review.quality) else {
                    if hasContentInstruction { throw contentReviewFailure() }
                    try record(LumenError.invalidResponse("Expected one review with a quality from 0 to 1."), for: input.photo)
                    continue
                }
                reviews[input.photo] = review
                if review.matchesInstruction { verifiedInstructionPhotos.insert(input.photo) }
                results[input.photo]?.levelLine = review.levelLine
                events.yield(.reviewed(review))
            }
        } catch is BatchCallLimit {
            if hasContentInstruction { throw contentReviewFailure() }
            return
        } catch {
            // A review that failed as a whole (a timeout, a refusal) leaves its photos judged by measurement, as without
            // a reviewer, so they still get their base pass: one slow answer lost a whole shoot's edit.
            if isCancellation(error) { throw LumenError.cancelled }
            if hasContentInstruction { throw contentReviewFailure() }
            for input in inputs {
                let review = measuredReview(input.photo, facts: input.facts)
                reviews[input.photo] = review
                results[input.photo]?.levelLine = review.levelLine
                note("The library review failed (\(error.localizedDescription)), so this photo was judged by measurement.", for: input.photo)
                events.yield(.reviewed(review))
            }
        }
    }

    private var hasContentInstruction: Bool {
        options.instruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func contentReviewFailure() -> LumenError {
        .invalidResponse("The visual content review could not be completed. No photos were changed. Try planning again before applying the requested edit.")
    }

    /// Measurement-only quality averages detail, balanced exposure and unclipped coverage.
    private func measuredReview(_ photo: PhotoID, facts: PhotoFacts) -> PhotoReview {
        func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        let quality = (unit(facts.sharpness) + unit(1 - abs(2 * facts.exposure - 1))
                       + unit(1 - facts.clippedShadows - facts.clippedHighlights)) / 3
        let reason: String?
        if facts.sharpness < 0.05 {
            reason = "Almost no fine detail was measured."
        } else if let peak = facts.peakSharpness, peak.isFinite, peak < 0.06 {
            // A shaken frame keeps enough fine detail as a whole (0.08) but is sharp nowhere, as a reviewer's blur
            // flag is confirmed.
            reason = "No part of the photo is sharp."
        } else if facts.exposure < 0.03 {
            reason = "The photo is almost black."
        } else if facts.exposure > 0.97 {
            reason = "The photo is almost white."
        } else {
            reason = nil
        }
        return PhotoReview(photo: photo, misfire: reason != nil, misfireReason: reason, quality: quality,
                           description: "Measured photo", group: photo.rawValue, matchesInstruction: false)
    }

    private func isMisfire(_ photo: PhotoID) -> Bool {
        guard options.flagMisfires, let review = reviews[photo], review.misfire else { return false }
        return !Self.sharpSomewhere(review, facts[photo])
    }

    /// A photo the reviewer called blurred that is sharp somewhere is not a misfire: soft storm clouds over a crisp town
    /// look blurred in a contact sheet's small cell. A shaken frame or a pocket shot is sharp nowhere.
    static func sharpSomewhere(_ review: PhotoReview, _ facts: PhotoFacts?) -> Bool {
        let reason = (review.misfireReason ?? "").lowercased()
        let aboutBlur = ["blur", "focus", "motion", "shak", "soft", "smear"].contains { reason.contains($0) }
        guard aboutBlur, let peak = facts?.peakSharpness, peak.isFinite else { return false }
        return peak >= 0.06
    }

    private func flagMisfires() async throws {
        guard options.flagMisfires else { return }
        for photo in photos where !excludedPhotos.contains(photo) && isMisfire(photo) {
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
        guard !excludedPhotos.contains(photo), results[photo]?.failed == false else { return }
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

    /// The photos whose camera was rolled. Vision's horizon reads perspective, a receding shore or a forest's slope as
    /// tilt too, so the photo's own straight lines must agree before anything is rotated. Long upright lines (walls,
    /// poles, frames) stand plumb unless the camera was rolled, and decide where there are enough of them; horizontals
    /// in a street recede with perspective, so long level lines decide only without them, and not in a close-up or
    /// studio photo, which the reviewer says has nothing that should be level. With neither, nothing is rotated.
    private func tilted(_ kept: [PhotoID]) -> [PhotoID] {
        kept.filter { photo in
            guard let facts = facts[photo], let tilt = facts.tilt, tilt.isFinite, abs(tilt) >= 0.5, abs(tilt) <= 7 else {
                return false
            }
            func agrees(_ measured: Double) -> Bool { abs(measured - tilt) <= max(0.7, abs(tilt) * 0.5) }
            if let lean = facts.verticalLean, lean.isFinite { return agrees(lean) }
            if let level = facts.levelTilt, level.isFinite, reviews[photo]?.levelLine != LevelLine.none { return agrees(level) }
            return false
        }
    }

    private func decideStraightening(_ kept: [PhotoID]) async throws -> Bool {
        if let straighten = options.straighten { return straighten }
        let tilted = tilted(kept)
        guard !tilted.isEmpty else { return false }
        let tilts = tilted.compactMap { facts[$0]?.tilt }.map(abs)
        let maximum = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), tilts.max() ?? 0)
        let recommended = tilts.filter { $0 >= 1 }.count > tilts.count / 2 ? 0 : 1
        let question = BatchQuestion(id: "straighten", question: tilted.count == 1 ? "1 photo looks tilted, by \(maximum)°. Straighten it?"
                                         : "\(tilted.count) photos look tilted, by up to \(maximum)°. Straighten them?",
                                     options: ["Straighten them", "Leave them"], recommended: recommended, photos: tilted)
        return try await choose(question) == "Straighten them"
    }

    private func straightenPhotos(_ kept: [PhotoID], enabled: Bool) async throws {
        guard enabled else { return }
        try await batchForEach(tilted(kept), limit: options.concurrency) { photo in
            try await self.straighten(photo)
        }
    }

    private func straighten(_ photo: PhotoID) async throws {
        guard !excludedPhotos.contains(photo), results[photo]?.failed == false, let tilt = facts[photo]?.tilt else { return }
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
        let low = kept.filter { !excludedPhotos.contains($0) && (reviews[$0]?.quality ?? 1) < options.qualityThreshold }
        try await batchForEach(low, limit: options.concurrency) { photo in
            try await self.edit(photo, instruction: self.closerLook)
        }
    }

    private func instructionPlan(_ kept: [PhotoID], straighten: Bool) async throws -> BatchPlan {
        let basePhotos = Set(plannedActions(kept, straighten: straighten).map(\.photo))
        guard let instruction = options.instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let plan = basePlan(kept, basePhotos: basePhotos)
            events.yield(.planned(plan))
            return plan
        }
        guard let reviewer else {
            let plan = BatchPlan(summary: instruction, groups: [BatchGroup(id: "library", title: "Library", photos: kept, instruction: instruction)])
            events.yield(.planned(plan))
            return plan
        }
        // Text planning receives only photos admitted by the successful visual
        // review. It may narrow that set, never overrule a negative decision.
        let matching = kept.filter { verifiedInstructionPhotos.contains($0) }.compactMap { reviews[$0] }
        guard !matching.isEmpty else {
            let plan = basePlan(kept, basePhotos: basePhotos)
            events.yield(.planned(plan))
            return plan
        }
        var latest = basePlan(kept, basePhotos: basePhotos)
        for round in 0..<3 {
            let request = BatchPlanRequest(instruction: instruction, reviews: matching,
                                           answers: Dictionary(uniqueKeysWithValues: answers.map { ($0.question.id, $0.answer) }))
            do {
                latest = try await call(.plan, model: reviewer.planModelID, detail: instruction,
                                        phase: .planning(model: reviewer.planModelID)) { try await reviewer.plan(request) }
            } catch is BatchCallLimit {
                for review in matching { note("Instruction skipped: model call limit reached.", for: review.photo) }
                latest = basePlan(kept, basePhotos: basePhotos)
                break
            }
            latest = checked(latest, kept: kept, matching: Set(matching.map(\.photo)), basePhotos: basePhotos)
            events.yield(.planned(latest))
            if latest.questions.isEmpty { return latest }
            for question in latest.questions { _ = try await choose(question, recommendationOnly: round == 2) }
        }
        latest.questions = []
        events.yield(.planned(latest))
        return latest
    }

    private func basePlan(_ kept: [PhotoID], basePhotos: Set<PhotoID>) -> BatchPlan {
        let changing = kept.filter { basePhotos.contains($0) }
        return BatchPlan(summary: basePhotos.isEmpty ? "No changes are planned for these photos."
                  : hasContentInstruction && reviewer != nil
                  ? "Only the separately listed base actions are planned; no instruction edits are planned."
                  : "Apply the base pass and give low-quality photos a closer look.",
                  groups: changing.isEmpty ? [] : [BatchGroup(id: "library", title: "Library", photos: changing, instruction: nil)])
    }

    private func checked(_ plan: BatchPlan, kept: [PhotoID], matching: Set<PhotoID>, basePhotos: Set<PhotoID>) -> BatchPlan {
        var plan = plan
        let allowedBase = Set(kept)
        var seen: Set<PhotoID> = []
        var groupIDs: Set<String> = []
        plan.groups = plan.groups.compactMap { group in
            var group = group
            let baseID = group.id.trimmingCharacters(in: .whitespacesAndNewlines)
            group.id = baseID.isEmpty ? "group" : baseID
            while !groupIDs.insert(group.id).inserted { group.id += "-group" }
            var inGroup: Set<PhotoID> = []
            let allowed = group.instruction == nil ? allowedBase.intersection(basePhotos) : matching
            group.photos = group.photos.filter { allowed.contains($0) && inGroup.insert($0).inserted }
            seen.formUnion(group.photos)
            return group.photos.isEmpty ? nil : group
        }
        let other = kept.filter { !seen.contains($0) && basePhotos.contains($0) }
        if !other.isEmpty {
            var id = "base"
            while plan.groups.contains(where: { $0.id == id }) { id += "-base" }
            plan.groups.append(BatchGroup(id: id, title: "Base pass", photos: other, instruction: nil))
        }
        let retainedGroups = Set(plan.groups.map(\.id))
        plan.questions = plan.questions.compactMap { question in
            var question = question
            if !question.groups.isEmpty {
                question.groups = question.groups.filter { retainedGroups.contains($0) }
                guard !question.groups.isEmpty else { return nil }
            }
            question.photos = question.photos?.filter { allowedBase.contains($0) }
            return question
        }
        if !plan.groups.contains(where: { $0.instruction != nil }) {
            plan.summary = basePlan(kept, basePhotos: basePhotos).summary
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

    private func waitForApproval() async throws -> BatchPlan {
        try checkCancellation()
        if approved, let token = pendingPlan?.approvalToken {
            _ = try approve(BatchApproval(approvalToken: token))
        }
        let plan: BatchPlan
        if let acceptedPlan { plan = acceptedPlan }
        else { plan = try await withCheckedThrowingContinuation { approvalWaiter = $0 } }
        try checkCancellation()
        return plan
    }

    private func plannedActions(_ kept: [PhotoID], straighten: Bool) -> [BatchPhotoActions] {
        let kept = Set(kept)
        let tilted = Set(straighten ? tilted(Array(kept)) : [])
        return photos.compactMap { photo in
            guard results[photo]?.failed == false, reviews[photo] != nil else { return nil }
            if isMisfire(photo) {
                return BatchPhotoActions(photo: photo, flagReason: reviews[photo]?.misfireReason ?? "The shot misfired.")
            }
            guard kept.contains(photo) else { return nil }
            let actions = BatchPhotoActions(photo: photo, auto: options.auto,
                                            straightenDegrees: tilted.contains(photo) ? facts[photo]?.tilt.map { -$0 } : nil,
                                            closerLook: (reviews[photo]?.quality ?? 1) < options.qualityThreshold)
            return actions.hasChanges ? actions : nil
        }
    }

    private func estimated(_ plan: BatchPlan, kept: [PhotoID], revisedInstructions: Bool = false) -> BatchPlan {
        var plan = plan
        let edits = estimatedEdits(plan, kept: kept)
        // New wording can require another pass. This remains a planning estimate, never a spending limit.
        let rounds = revisedInstructions ? max(1, configuration.maxRevisions + 1) : 1
        let (calls, overflow) = edits.multipliedReportingOverflow(by: 5 * rounds)
        plan.estimatedModelCalls = overflow ? Int.max : calls
        if let pricing = planner as? any PhotoCostEstimating {
            let measured = BatchSummary(photos: Array(results.values), answers: [], modelCalls: 0, duration: 0)
            plan.estimatedCost = measured.estimatedCost(for: edits, defaultCostPerPhoto: pricing.estimatedCostPerPhoto) * Double(rounds)
        }
        return plan
    }

    private func estimatedEdits(_ plan: BatchPlan, kept: [PhotoID]) -> Int {
        let instructed = plan.groups.filter { $0.instruction != nil }.reduce(0) { $0 + $1.photos.count }
        let closer = kept.filter { (reviews[$0]?.quality ?? 1) < options.qualityThreshold }.count
        return instructed + closer
    }

    private func edit(_ photo: PhotoID, instruction: String) async throws {
        guard !excludedPhotos.contains(photo), results[photo]?.failed == false else { return }
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
            // A step that failed is a failure only if the edit didn't recover from it: the shirts SAM didn't find by
            // one name, it found by another on the critic's revision, and the photo was marked failed all the same.
            var stepFailed = false
            // A critique judges the pixels at that point. A later simple
            // revision may finish directly under EditAgent's result contract.
            var currentVerdict: Bool?
            try await withTaskCancellationHandler {
                for try await event in agent.run(instruction) {
                    try checkCancellation()
                    if case .trace(let trace) = event {
                        let recorded = await calls.record(trace, reservation: reservation)
                        traces.append(recorded)
                        if let cost = recorded.cost {
                            let previous = results[photo]?.cost ?? 0
                            results[photo]?.cost = previous + cost
                        }
                        events.yield(.edit(photo, .trace(recorded)))
                    } else {
                        events.yield(.edit(photo, event))
                    }
                    switch event {
                    case .applied, .reverted:
                        changed.insert(photo)
                        currentVerdict = nil
                    case .finished(let reason):
                        note(reason, for: photo)
                    case .critiqued(let critique):
                        currentVerdict = critique.satisfied
                    case .trace(let trace) where trace.kind == .failure:
                        stepFailed = true
                        note(trace.detail, for: photo)
                    default:
                        break
                    }
                }
                try checkCancellation()
                if currentVerdict == false || (stepFailed && currentVerdict != true) {
                    results[photo]?.failed = true
                }
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
        guard !excludedPhotos.contains(photo) else { return }
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
                                      phase: BatchPhase? = nil,
                                      operation: @Sendable () async throws -> Value) async throws -> Value {
        try checkCancellation()
        try await calls.begin()
        if let phase { events.yield(.phase(phase)) }
        let started = Date()
        let usage = ModelUsageRecorder()
        let notes = ModelCallNoteRecorder()
        do {
            let value = try await ModelUsageReporting.$report.withValue(usage.record) {
                try await ModelCallNotes.$report.withValue(notes.record) { try await operation() }
            }
            try checkCancellation()
            recordTrace(TraceEvent(kind: kind, model: model, detail: notes.detail(detail), started: started,
                                           duration: max(0, Date().timeIntervalSince(started))).recording(usage.value))
            return value
        } catch {
            recordTrace(TraceEvent(kind: kind, model: model, detail: notes.detail(error.localizedDescription), started: started,
                                           duration: max(0, Date().timeIntervalSince(started))).recording(usage.value))
            throw error
        }
    }

    private func recordTrace(_ trace: TraceEvent) {
        traces.append(trace)
        events.yield(.trace(trace))
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
