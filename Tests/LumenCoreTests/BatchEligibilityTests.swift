import Testing
@testable import LumenCore

@Suite("Batch target eligibility", .timeLimit(.minutes(1)))
struct BatchEligibilityTests {
    @Test func textPlannerCannotAddPhotosRejectedByVisualReview() async throws {
        let shirt = PhotoID("photo-0"), car = PhotoID("photo-1"), lake = PhotoID("photo-2")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(), batchTestFacts()])
        let proposed = BatchPlan(summary: "Blue shirts", groups: [
            BatchGroup(id: "shirts", title: "Shirts to blue", photos: [shirt, car, lake], instruction: "Make the shirts blue")
        ])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(shirt), batchTestReview(car, matches: false),
                                                  batchTestReview(lake, matches: false)], plans: [proposed])
        let agent = batchTestAgent(library, reviewer: reviewer)
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Make the shirts blue",
                                                           auto: true, straighten: false, qualityThreshold: 0)) {
            if case .awaitingApproval(let plan, _) = event {
                #expect(plan.groups.first { $0.id == "shirts" }?.photos == [shirt])
                #expect(Set(plan.groups.filter { $0.instruction == nil }.flatMap(\.photos)) == [car, lake])
                #expect(await library.edited.isEmpty)
                _ = try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken)))
            }
        }
        #expect(await library.edited == [shirt])
        #expect(Set(await library.autos) == [shirt, car, lake])
    }

    @Test func failedContentReviewCannotAuthorizeInstructionEditsOrBaseMutations() async throws {
        for mode in [BatchMode.planFirst, .autonomous] {
            let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(sharpness: 0.01)])
            let reviewer = BatchTestReviewer(reviewError: LumenError.timedOut)
            let agent = batchTestAgent(library, reviewer: reviewer)
            do {
                // Drive every wait so a safety failure is observed as an
                // unwanted mutation/result, never a hanging approval driver.
                for try await event in await agent.run(BatchOptions(mode: mode, instruction: "Make the shirts blue",
                                                                    auto: true, straighten: false)) {
                    if case .question(let question) = event {
                        await agent.answer(question.id, with: question.options[question.recommended])
                    }
                    if case .awaitingApproval(let plan, _) = event {
                        _ = try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken)))
                    }
                }
                Issue.record("A failed visual review must not become permission to edit every photo")
            } catch {
                #expect(error is LumenError)
            }
            #expect(await library.edited.isEmpty)
            #expect(await library.autos.isEmpty)
            #expect(await library.flags.isEmpty)
            #expect(await reviewer.planRequests.isEmpty)
        }
    }

    @Test func questionForAnIneligibleGroupDoesNotAskAboutUnrelatedPhotos() async throws {
        let photo = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts()])
        let proposed = BatchPlan(summary: "Blue shirts", groups: [
            BatchGroup(id: "shirts", title: "Shirts", photos: [photo], instruction: "Make the shirt blue")
        ], questions: [BatchQuestion(id: "shade", question: "Which blue?", options: ["Navy", "Sky"], recommended: 0,
                                    groups: ["shirts"])])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(photo, matches: false)], plans: [proposed])
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer).run(
            BatchOptions(mode: .autonomous, instruction: "Make the shirts blue", auto: false, straighten: false,
                         qualityThreshold: 0)))
        #expect(events.batchQuestions.isEmpty)
        #expect(events.batchEdits.isEmpty)
        #expect(await reviewer.planRequests.isEmpty)
    }

    @Test func malformedContentReviewStopsBeforeAnyBaseOrFlagWrite() async throws {
        let first = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts(sharpness: 0.01), batchTestFacts()])
        let reviewer = BatchTestReviewer(reviewResponse: [batchTestReview(first), batchTestReview(first)])
        let agent = batchTestAgent(library, reviewer: reviewer)
        await #expect(throws: LumenError.self) {
            _ = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Change the shirts",
                                                                       auto: true, straighten: false)))
        }
        #expect(await library.flags.isEmpty)
        #expect(await library.autos.isEmpty)
        #expect(await library.saved.isEmpty)
        #expect(await library.edited.isEmpty)
        #expect(await reviewer.planRequests.isEmpty)
    }

    @Test func rejectedPhotosStayInExplicitBaseGroupsButCannotBePromotedByDraftEditing() async throws {
        let shirt = PhotoID("photo-0"), car = PhotoID("photo-1")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let proposed = BatchPlan(summary: "Blue shirts", groups: [
            BatchGroup(id: "shirts", title: "Shirts", photos: [shirt], instruction: "Make the shirt blue"),
            BatchGroup(id: "base", title: "Base", photos: [car], instruction: nil),
        ])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(shirt), batchTestReview(car, matches: false)], plans: [proposed])
        let agent = batchTestAgent(library, reviewer: reviewer)
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Make shirts blue", auto: true,
                                                           straighten: false, qualityThreshold: 0)) {
            if case .awaitingApproval(let plan, _) = event {
                let token = try #require(plan.approvalToken)
                #expect(plan.groups.first { $0.id == "base" }?.photos == [car])
                await #expect(throws: LumenError.self) {
                    _ = try await agent.previewApproval(BatchApproval(approvalToken: token, instructionOverrides: ["base": "Make the shirt blue"]))
                }
                _ = try await agent.approve(BatchApproval(approvalToken: token, excludedPhotoIDs: [shirt]))
                await #expect(throws: BatchApprovalError.self) {
                    _ = try await agent.approve(BatchApproval(approvalToken: token))
                }
            }
        }
        #expect(await library.edited.isEmpty)
        #expect(await library.autos == [car])
        #expect(await reviewer.planRequests.allSatisfy { $0.reviews.map(\.photo) == [shirt] })
    }

    @Test func removingOnlyRejectedInstructedGroupsDropsTheirQuestionsAndClaim() async throws {
        let shirt = PhotoID("photo-0"), car = PhotoID("photo-1")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(shirt), batchTestReview(car, matches: false)], plans: [
            BatchPlan(summary: "Make the car's shirt blue", groups: [
                BatchGroup(id: "wrong", title: "Wrong", photos: [car], instruction: "Make its shirt blue"),
            ], questions: [BatchQuestion(id: "wrong-q", question: "Which blue?", options: ["Navy", "Sky"], recommended: 0, groups: ["wrong"])])
        ])
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer).run(
            BatchOptions(mode: .autonomous, instruction: "Make shirts blue", auto: false, straighten: false, qualityThreshold: 0)))
        #expect(events.batchQuestions.isEmpty)
        #expect(events.batchEdits.isEmpty)
        let plans = events.compactMap { if case .planned(let plan) = $0 { plan } else { nil } }
        #expect(plans.allSatisfy { !$0.summary.contains("blue") && $0.groups.allSatisfy { $0.instruction == nil } })
    }
}
