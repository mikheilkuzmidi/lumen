import Foundation
import Testing
@testable import LumenCore

@Suite("Editable batch approval", .timeLimit(.minutes(1)))
struct BatchApprovalTests {
    @Test func revisedInstructionsRunAndExclusionsWinAcrossEveryStageAndGroup() async throws {
        let excluded = PhotoID("photo-0"), bad = PhotoID("photo-1"), kept = PhotoID("photo-2")
        let library = BatchTestLibrary([batchTestFacts(tilt: 3), batchTestFacts(), batchTestFacts(tilt: 2)])
        let plan = BatchPlan(summary: "Two edits", groups: [
            BatchGroup(id: "warm", title: "Warm", photos: [excluded, kept], instruction: "Warm it"),
            BatchGroup(id: "contrast", title: "Contrast", photos: [excluded, kept], instruction: "Add contrast"),
        ])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(excluded, quality: 0.1),
                                                  batchTestReview(bad, misfire: true)], plans: [plan])
        let planner = BatchTestPlanner()
        let agent = batchTestAgent(library, reviewer: reviewer, planner: planner)
        var events: [BatchEvent] = []
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Two edits", straighten: true, concurrency: 1)) {
            events.append(event)
            if case .awaitingApproval(let pending, _) = event {
                #expect(await library.flags.isEmpty)
                #expect(await library.autos.isEmpty)
                #expect(await library.rotations.isEmpty)
                #expect(await library.edited.isEmpty)
                #expect(await library.saved.isEmpty)
                #expect(pending.targetPhotos == [excluded, bad, kept])
                #expect(pending.photoActions?.first(where: { $0.photo == bad })?.flagReason == "Badly blurred")
                #expect(pending.photoActions?.first(where: { $0.photo == excluded })?.closerLook == true)
                let approval = BatchApproval(approvalToken: try #require(pending.approvalToken),
                                             instructionOverrides: ["warm": "Make the shirts green"],
                                             excludedPhotoIDs: [excluded, bad])
                let draft = try await agent.previewApproval(approval)
                #expect(draft.groups.allSatisfy { $0.photos == [kept] })
                #expect(draft.photoActions?.map(\.photo) == [kept])
                #expect(await library.autos.isEmpty)
                let accepted = try await agent.approve(approval)
                #expect(accepted == draft)
            }
        }
        #expect(await planner.plans.map(\.instruction) == ["Make the shirts green", "Add contrast"])
        #expect(await library.flags.isEmpty)
        #expect(await library.autos == [kept])
        #expect(await library.rotations == [kept: -2])
        #expect(await library.edited == [kept, kept])
        #expect(await library.saved == [kept])
        let summary = try batchTestSummary(events)
        #expect(summary.photos.filter { $0.photo != kept }.allSatisfy {
            $0.outcome == "Skipped: excluded from the approved plan." && !$0.failed && $0.instruction == nil
        })
        #expect(events.batchProgress.last == 3)
    }

    @Test func invalidDraftsDoNotConsumeThePendingPlanOrChangePhotos() async throws {
        let photo = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts()])
        let agent = batchTestAgent(library)
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Warm it", straighten: false)) {
            if case .awaitingApproval(let plan, _) = event {
                let token = try #require(plan.approvalToken)
                await #expect(throws: BatchApprovalError.staleToken) {
                    try await agent.approve(BatchApproval(approvalToken: UUID()))
                }
                await #expect(throws: BatchApprovalError.unknownGroup("missing")) {
                    try await agent.approve(BatchApproval(approvalToken: token, instructionOverrides: ["missing": "Blue"]))
                }
                await #expect(throws: BatchApprovalError.emptyInstruction("library")) {
                    try await agent.approve(BatchApproval(approvalToken: token, instructionOverrides: ["library": " \n "]))
                }
                await #expect(throws: BatchApprovalError.unknownPhoto(PhotoID("outside"))) {
                    try await agent.approve(BatchApproval(approvalToken: token, excludedPhotoIDs: [PhotoID("outside")]))
                }
                await #expect(throws: BatchApprovalError.duplicateExcludedPhoto(photo)) {
                    try await agent.approve(BatchApproval(approvalToken: token, excludedPhotoIDs: [photo, photo]))
                }
                #expect(await library.autos.isEmpty)
                #expect(await library.edited.isEmpty)
                try await agent.approve(BatchApproval(approvalToken: token))
                await #expect(throws: BatchApprovalError.noPendingPlan) {
                    try await agent.approve(BatchApproval(approvalToken: token))
                }
            }
        }
        #expect(await library.autos == [photo])
        #expect(await library.edited == [photo])
    }

    @Test func excludingEveryPhotoLeavesFlagsBaseEditsAndSavesUntouched() async throws {
        let library = BatchTestLibrary([batchTestFacts(sharpness: 0.01), batchTestFacts(tilt: 2)])
        let planner = BatchTestPlanner()
        let agent = batchTestAgent(library, planner: planner)
        var events: [BatchEvent] = []
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Warm it", straighten: true)) {
            events.append(event)
            if case .awaitingApproval(let plan, _) = event {
                let draft = try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken),
                                                                 excludedPhotoIDs: try #require(plan.targetPhotos)))
                #expect(draft.groups.isEmpty)
                #expect(draft.photoActions?.isEmpty == true)
                #expect(draft.estimatedModelCalls == 0)
            }
        }
        #expect(await library.flags.isEmpty)
        #expect(await library.autos.isEmpty)
        #expect(await library.rotations.isEmpty)
        #expect(await library.edited.isEmpty)
        #expect(await library.saved.isEmpty)
        #expect(await planner.plans.isEmpty)
        #expect(try batchTestSummary(events).photos.count == 2)
    }

    @Test func verifiedBaseActionGroupCanGainAnInstructionAndPreviewRecalculatesItsEstimate() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let planner = BatchTestPlanner()
        let reviewer = BatchTestReviewer(plans: [BatchPlan(summary: "Base actions", groups: [
            BatchGroup(id: "library", title: "Library", photos: [PhotoID("photo-0"), PhotoID("photo-1")], instruction: nil),
        ])])
        let agent = BatchAgent(host: library, reviewer: reviewer, planner: ApprovalPricedPlanner(base: planner),
                               segmenter: BatchTestSegmenter(), generator: BatchTestGenerator())
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Make shirts blue", auto: true,
                                                           straighten: false, qualityThreshold: 0)) {
            if case .awaitingApproval(let plan, let calls) = event {
                #expect(calls == 0)
                #expect(plan.estimatedCost == 0)
                let approval = BatchApproval(approvalToken: try #require(plan.approvalToken),
                                             instructionOverrides: ["library": " Make it warmer "],
                                             excludedPhotoIDs: [PhotoID("photo-1")])
                let draft = try await agent.previewApproval(approval)
                #expect(draft.estimatedModelCalls == 15)
                #expect(draft.estimatedCost == 0.09)
                #expect(await planner.plans.isEmpty)
                #expect(await library.autos.isEmpty)
                #expect(await library.saved.isEmpty)
                try await agent.approve(approval)
            }
        }
        #expect(await planner.plans.map(\.instruction) == ["Make it warmer"])
        #expect(await library.autos == [PhotoID("photo-0")])
        #expect(await library.saved == [PhotoID("photo-0")])
    }

    @Test func tokenCannotApproveAnotherRun() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let agent = batchTestAgent(library)
        var previous: UUID?
        for _ in 0..<2 {
            for try await event in await agent.run(BatchOptions(mode: .planFirst, auto: false, straighten: false, qualityThreshold: 0)) {
                if case .awaitingApproval(let plan, _) = event {
                    let token = try #require(plan.approvalToken)
                    if let previous {
                        #expect(previous != token)
                        await #expect(throws: BatchApprovalError.staleToken) {
                            try await agent.approve(BatchApproval(approvalToken: previous))
                        }
                    }
                    try await agent.approve(BatchApproval(approvalToken: token))
                    previous = token
                }
            }
        }
        #expect(await library.saved.isEmpty)
    }

    @Test func cancelledPlanRejectsApprovalAndDoesNotMutate() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let agent = batchTestAgent(library)
        do {
            for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Warm it", straighten: false)) {
                if case .awaitingApproval(let plan, _) = event {
                    await agent.cancel()
                    await #expect(throws: LumenError.cancelled) {
                        try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken)))
                    }
                }
            }
            Issue.record("Cancellation must end the stream with an error.")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await library.autos.isEmpty)
        #expect(await library.edited.isEmpty)
        #expect(await library.saved.isEmpty)
    }

    @Test func legacyPlansStillDecodeAndNewApprovalMetadataRoundTrips() throws {
        let plan = try JSONDecoder().decode(BatchPlan.self, from: Data(#"{"summary":"Old","groups":[],"questions":[]}"#.utf8))
        #expect(plan.approvalToken == nil)
        #expect(plan.targetPhotos == nil)
        #expect(plan.photoActions == nil)
        #expect(plan.estimatedModelCalls == nil)
        let new = BatchPlan(summary: "New", groups: [], approvalToken: UUID(), targetPhotos: [PhotoID("one")],
                            photoActions: [BatchPhotoActions(photo: PhotoID("one"), auto: true)], estimatedModelCalls: 5)
        #expect(try JSONDecoder().decode(BatchPlan.self, from: JSONEncoder().encode(new)) == new)
    }

    @Test func duplicatePlannerGroupIDsBecomeUnambiguousForOverrides() async throws {
        let photo = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts()])
        let plan = BatchPlan(summary: "Two groups", groups: [
            BatchGroup(id: "same", title: "Warm", photos: [photo], instruction: "Warm it"),
            BatchGroup(id: "same", title: "Contrast", photos: [photo], instruction: "More contrast"),
        ])
        let planner = BatchTestPlanner()
        let agent = batchTestAgent(library, reviewer: BatchTestReviewer(plans: [plan]), planner: planner)
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Two groups", auto: false, straighten: false)) {
            if case .awaitingApproval(let plan, _) = event {
                #expect(plan.groups.map(\.id) == ["same", "same-group"])
                try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken),
                                                      instructionOverrides: ["same-group": "Cool it"]))
            }
        }
        #expect(await planner.plans.map(\.instruction) == ["Warm it", "Cool it"])
    }
}

private struct ApprovalPricedPlanner: Planner, PhotoCostEstimating {
    let base: BatchTestPlanner
    var modelID: String { "priced-planner" }
    var estimatedCostPerPhoto: Double { 0.03 }
    func plan(_ request: PlanRequest) async throws -> EditPlan { try await base.plan(request) }
    func critique(_ request: CritiqueRequest) async throws -> Critique { try await base.critique(request) }
}
