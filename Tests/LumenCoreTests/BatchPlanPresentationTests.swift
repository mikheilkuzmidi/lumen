import Foundation
import Testing
@testable import LumenCore

@Suite("Meaningful batch approval", .timeLimit(.minutes(1)))
struct BatchPlanPresentationTests {
    @Test func aRejectedPhotoWithNoBaseWorkIsNotPresentedAsAnEdit() async throws {
        let shirt = PhotoID("photo-0"), car = PhotoID("photo-1")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(shirt), batchTestReview(car, matches: false)], plans: [
            BatchPlan(summary: "Make shirts blue", groups: [
                BatchGroup(id: "shirts", title: "Blue shirts", photos: [shirt], instruction: "Make the shirt blue"),
            ])
        ])
        let agent = batchTestAgent(library, reviewer: reviewer)
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Make shirts blue",
                                                           auto: false, straighten: false, flagMisfires: false,
                                                           qualityThreshold: 0)) {
            if case .awaitingApproval(let plan, _) = event {
                // The full scope remains frozen even when one photo needs no change.
                #expect(plan.targetPhotos == [shirt, car])
                #expect(plan.groups.flatMap(\.photos) == [shirt])
                #expect(plan.photoActions?.isEmpty == true)
                #expect(plan.changingPhotoIDs == [shirt])
                #expect(await library.edited.isEmpty)
                _ = try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken)))
            }
        }
        #expect(await library.edited == [shirt])
        #expect(await library.saved == [shirt])
        #expect(await library.autos.isEmpty)
        #expect(await library.flags.isEmpty)
    }

    @Test func explicitBaseActionsStillCountAndRejectedNoOpPhotosCannotBePromoted() async throws {
        let shirt = PhotoID("photo-0"), tilted = PhotoID("photo-1"), car = PhotoID("photo-2")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(tilt: 2), batchTestFacts()])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(shirt), batchTestReview(tilted, matches: false),
                                                  batchTestReview(car, matches: false)], plans: [
            BatchPlan(summary: "Make shirts blue", groups: [
                BatchGroup(id: "shirts", title: "Blue shirts", photos: [shirt], instruction: "Make the shirt blue"),
                BatchGroup(id: "noop", title: "Base pass", photos: [car], instruction: nil),
            ])
        ])
        let agent = batchTestAgent(library, reviewer: reviewer)
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Make shirts blue", auto: false,
                                                           straighten: true, flagMisfires: false, qualityThreshold: 0)) {
            if case .awaitingApproval(let plan, _) = event {
                #expect(plan.targetPhotos == [shirt, tilted, car])
                #expect(plan.changingPhotoIDs == [shirt, tilted])
                #expect(plan.groups.first { $0.instruction == nil }?.photos == [tilted])
                #expect(plan.groups.allSatisfy { $0.id != "noop" })
                let token = try #require(plan.approvalToken)
                await #expect(throws: BatchApprovalError.unknownGroup("noop")) {
                    _ = try await agent.previewApproval(BatchApproval(approvalToken: token, instructionOverrides: ["noop": "Make the car blue"]))
                }
                let revised = try await agent.previewApproval(BatchApproval(approvalToken: token,
                                                                           instructionOverrides: ["shirts": "Make the shirt navy"],
                                                                           excludedPhotoIDs: [tilted]))
                #expect(revised.changingPhotoIDs == [shirt])
                _ = try await agent.approve(BatchApproval(approvalToken: token, excludedPhotoIDs: [shirt, tilted]))
            }
        }
        #expect(await library.edited.isEmpty)
        #expect(await library.rotations.isEmpty)
        #expect(await library.saved.isEmpty)
    }

    @Test func approvalIDsDeduplicateActualOperationsAndKeepLegacyPlansCompatible() {
        let a = PhotoID("a"), b = PhotoID("b"), c = PhotoID("c"), d = PhotoID("d"), unchanged = PhotoID("unchanged")
        let group = BatchGroup(id: "edit", title: "Edit", photos: [a, a], instruction: "Make it blue")
        let plan = BatchPlan(summary: "Edit", groups: [group], targetPhotos: [unchanged, d, b, a, c], photoActions: [
            BatchPhotoActions(photo: a, auto: true), BatchPhotoActions(photo: b, flagReason: "Misfire"),
            BatchPhotoActions(photo: c, closerLook: true), BatchPhotoActions(photo: d, straightenDegrees: -2),
            BatchPhotoActions(photo: unchanged),
        ])
        #expect(plan.changingPhotoIDs == [d, b, a, c])
        #expect(!BatchPhotoActions(photo: unchanged).hasChanges)
        let legacy = BatchPlan(summary: "Base", groups: [BatchGroup(id: "base", title: "Base", photos: [a, b], instruction: nil)])
        #expect(legacy.changingPhotoIDs == [a, b])
    }

    @Test func aNoOpScopeCannotBeTurnedIntoInstructionEditsThroughDraftOverrides() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let agent = batchTestAgent(library)
        for try await event in await agent.run(BatchOptions(mode: .planFirst, auto: false, straighten: false,
                                                           flagMisfires: false, qualityThreshold: 0)) {
            if case .awaitingApproval(let plan, _) = event {
                #expect(plan.targetPhotos == [PhotoID("photo-0")])
                #expect(plan.groups.isEmpty)
                #expect(plan.changingPhotoIDs.isEmpty)
                let token = try #require(plan.approvalToken)
                await #expect(throws: BatchApprovalError.unknownGroup("library")) {
                    _ = try await agent.previewApproval(BatchApproval(approvalToken: token,
                                                                     instructionOverrides: ["library": "Make the shirt blue"]))
                }
                _ = try await agent.approve(BatchApproval(approvalToken: token))
            }
        }
        #expect(await library.edited.isEmpty)
        #expect(await library.saved.isEmpty)
    }
}
