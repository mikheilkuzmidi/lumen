import Foundation
import Testing
@testable import LumenCore

@Suite("Batch agent", .timeLimit(.minutes(1)))
struct BatchAgentTests {
    @Test func misfiresAreFlaggedAndSkippedByEveryLaterStage() async throws {
        let bad = PhotoID("photo-0")
        let good = PhotoID("photo-1")
        let library = BatchTestLibrary([batchTestFacts(tilt: 3), batchTestFacts(tilt: -2)])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(bad, quality: 0.1, misfire: true)])
        let agent = batchTestAgent(library, reviewer: reviewer)
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Blue shirts", straighten: true)))
        let summary = try batchTestSummary(events)
        #expect(await library.flags == [bad: "Badly blurred"])
        #expect(await library.autos == [good])
        #expect(await library.rotations == [good: 2])
        #expect(await library.edited == [good])
        #expect(await library.saved == [good])
        #expect(await reviewer.planRequests.first?.reviews.map(\.photo) == [good])
        #expect(summary.photos.map(\.photo) == [bad, good])
        #expect(summary.photos[0].flagged == "Badly blurred")
        #expect(summary.photos[0].instruction == nil)
        #expect(events.batchProgress == [1, 2])
        #expect(events.batchTraces.filter { $0.model != nil }.count == summary.modelCalls)
    }

    @Test func aPhotoSharpSomewhereIsNotFlaggedAsBlurred() async throws {
        // Storm clouds over a crisp town, called blurred from a contact sheet (photo-0); a shaken frame sharp nowhere
        // (photo-1); a pocket shot flagged for what it shows, not for blur (photo-2).
        var clouds = batchTestFacts(sharpness: 0.05); clouds.peakSharpness = 0.26
        var shaken = batchTestFacts(sharpness: 0.08); shaken.peakSharpness = 0.03
        var pocket = batchTestFacts(sharpness: 0.9); pocket.peakSharpness = 0.5
        let library = BatchTestLibrary([clouds, shaken, pocket])
        var reviews = [batchTestReview(PhotoID("photo-0"), quality: 0.2, misfire: true),
                       batchTestReview(PhotoID("photo-1"), quality: 0.1, misfire: true),
                       batchTestReview(PhotoID("photo-2"), quality: 0.1, misfire: true)]
        reviews[2].misfireReason = "Pocket shot of the floor"
        let agent = batchTestAgent(library, reviewer: BatchTestReviewer(reviews: reviews))
        _ = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, auto: false, straighten: false, qualityThreshold: 0)))
        #expect(await library.flags == [PhotoID("photo-1"): "Badly blurred", PhotoID("photo-2"): "Pocket shot of the floor"])
    }

    @Test func disablingMisfireFlagsKeepsThosePhotos() async throws {
        let photo = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts(sharpness: 0.01)])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(photo, quality: 0.1, misfire: true)])
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer).run(
            BatchOptions(mode: .autonomous, straighten: false, flagMisfires: false)))
        #expect(await library.flags.isEmpty)
        #expect(await library.autos == [photo])
        #expect(events.batchEdits == [photo])
        #expect(try batchTestSummary(events).photos[0].flagged == nil)
    }

    @Test(arguments: BatchMode.allCases, [true, false])
    func explicitStraighteningNeverAsks(mode: BatchMode, straighten: Bool) async throws {
        let library = BatchTestLibrary([batchTestFacts(tilt: 0.49), batchTestFacts(tilt: 0.5), batchTestFacts(tilt: -2)])
        let agent = batchTestAgent(library)
        await agent.approve()
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: mode, auto: false, straighten: straighten, qualityThreshold: 0)))
        #expect(events.batchQuestions.isEmpty)
        #expect(await library.rotations == (straighten ? [PhotoID("photo-1"): -0.5, PhotoID("photo-2"): 2] : [:]))
        #expect(try batchTestSummary(events).answers.isEmpty)
    }

    @Test func onlyTiltsThePhotosLinesConfirmAndSmallOnesAreStraightened() async throws {
        // Perspective read as tilt, the photo's walls standing plumb (photo-0), whatever the reviewer saw; a 7.5° tilt is
        // likely meant (photo-2); walls leaning with the horizon (photo-1, photo-3) mean a rolled camera.
        let library = BatchTestLibrary([batchTestFacts(tilt: 3, verticalLean: 0), batchTestFacts(tilt: 4), batchTestFacts(tilt: 7.5),
                                        batchTestFacts(tilt: -2)])
        let reviewer = BatchTestReviewer(reviews: [
            batchTestReview(PhotoID("photo-0"), tilted: true), batchTestReview(PhotoID("photo-1"), tilted: false),
            batchTestReview(PhotoID("photo-2"), tilted: true), batchTestReview(PhotoID("photo-3")),
        ])
        let agent = batchTestAgent(library, reviewer: reviewer)
        _ = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, auto: false, straighten: true, qualityThreshold: 0)))
        #expect(await library.rotations == [PhotoID("photo-1"): -4, PhotoID("photo-3"): 2])
    }

    @Test func levelLinesDecideWithoutUprightOnesButNotInACloseUp() async throws {
        // A lake with nothing upright, its shore tilted with the horizon (photo-0), is levelled though the reviewer saw
        // no tilt. In a close-up a level line is not a horizon (photo-1). A receding shore reads as tilt while the long
        // lines stay level (photo-2). With no lines at all, nothing confirms the reading (photo-3).
        let library = BatchTestLibrary([batchTestFacts(tilt: 3, levelTilt: 3), batchTestFacts(tilt: 2, levelTilt: 2),
                                        batchTestFacts(tilt: -1.5, levelTilt: 0), batchTestFacts(tilt: 4, noLines: true)])
        let reviewer = BatchTestReviewer(reviews: [
            batchTestReview(PhotoID("photo-0"), tilted: false, levelLine: .water),
            batchTestReview(PhotoID("photo-1"), tilted: true, levelLine: LevelLine.none),
            batchTestReview(PhotoID("photo-2"), tilted: true, levelLine: .horizon),
            batchTestReview(PhotoID("photo-3"), tilted: true, levelLine: .building),
        ])
        let agent = batchTestAgent(library, reviewer: reviewer)
        _ = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, auto: false, straighten: true, qualityThreshold: 0)))
        #expect(await library.rotations == [PhotoID("photo-0"): -3])
    }

    @Test func aSnapshotFromTheWaterIsLevelledUpToSevenDegrees() async throws {
        // A sea horizon tilted 6.8° (photo-0) is levelled; 7.5° with walls leaning the same way (photo-1) is likely meant;
        // 11° (photo-2) is past what a slip of the hand does.
        let library = BatchTestLibrary([batchTestFacts(tilt: -6.8, levelTilt: -7), batchTestFacts(tilt: 7.5),
                                        batchTestFacts(tilt: 11, levelTilt: 11)])
        let reviewer = BatchTestReviewer(reviews: [
            batchTestReview(PhotoID("photo-0"), tilted: true, levelLine: .water),
            batchTestReview(PhotoID("photo-1"), tilted: true, levelLine: .building),
            batchTestReview(PhotoID("photo-2"), tilted: true, levelLine: .horizon),
        ])
        let agent = batchTestAgent(library, reviewer: reviewer)
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, auto: false, straighten: true,
                                                                            qualityThreshold: 0)))
        #expect(await library.rotations == [PhotoID("photo-0"): 6.8])
        // The summary says what decided each: the measured tilt and the line that should be level.
        let summary = try #require(events.compactMap { if case .finished(let summary) = $0 { summary } else { nil } }.first)
        #expect(summary.photos.map(\.measuredTilt) == [-6.8, 7.5, 11])
        #expect(summary.photos.map(\.levelLine) == [.water, .building, .horizon])
    }

    @Test func uprightLinesDecideWhetherTheCameraWasRolled() async throws {
        // A harbour whose buildings lean with its horizon (photo-0) was rolled, though the reviewer saw no tilt. A city
        // above a strait whose minarets stand plumb (photo-1) has a receding shore, not a tilted horizon. A fountain's
        // rim the reviewer took for water (photo-2) is the same. A close-up whose window frame leans with the horizon
        // (photo-3) was rolled too.
        let library = BatchTestLibrary([batchTestFacts(tilt: -2.9, verticalLean: -2.0), batchTestFacts(tilt: -5.2, verticalLean: -1.9),
                                        batchTestFacts(tilt: -3, verticalLean: 0), batchTestFacts(tilt: 2, verticalLean: 2)])
        let reviewer = BatchTestReviewer(reviews: [
            batchTestReview(PhotoID("photo-0"), tilted: false, levelLine: .building),
            batchTestReview(PhotoID("photo-1"), tilted: true, levelLine: .horizon),
            batchTestReview(PhotoID("photo-2"), tilted: true, levelLine: .water),
            batchTestReview(PhotoID("photo-3"), tilted: true, levelLine: LevelLine.none),
        ])
        let agent = batchTestAgent(library, reviewer: reviewer)
        _ = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, auto: false, straighten: true, qualityThreshold: 0)))
        #expect(await library.rotations == [PhotoID("photo-0"): 2.9, PhotoID("photo-3"): -2])
    }

    @Test func oneTiltedPhotoIsAskedAboutAsOne() async throws {
        let library = BatchTestLibrary([batchTestFacts(tilt: 0.2), batchTestFacts(tilt: -2.5)])
        let agent = batchTestAgent(library)
        var asked: [String] = []
        for try await event in await agent.run(BatchOptions(mode: .askWhenUnsure, auto: false, qualityThreshold: 0)) {
            if case .question(let question) = event {
                asked.append(question.question)
                await agent.answer(question.id, with: "Leave them")
            }
            if case .awaitingApproval = event { await agent.approve() }
        }
        #expect(asked == ["1 photo looks tilted, by 2.5°. Straighten it?"])
    }

    @Test(arguments: BatchMode.allCases)
    func undecidedStraighteningAsksOrTakesTheRecommendation(mode: BatchMode) async throws {
        let library = BatchTestLibrary([batchTestFacts(tilt: 0.8), batchTestFacts(tilt: 1), batchTestFacts(tilt: -2.5)])
        let agent = batchTestAgent(library)
        let stream = await agent.run(BatchOptions(mode: mode, auto: false, qualityThreshold: 0))
        var events: [BatchEvent] = []
        for try await event in stream {
            events.append(event)
            if case .question(let question) = event {
                #expect(question.id == "straighten")
                #expect(question.question == "3 photos look tilted, by up to 2.5°. Straighten them?")
                #expect(question.options == ["Straighten them", "Leave them"])
                #expect(question.recommended == 0)
                #expect(await library.rotations.isEmpty)
                await agent.answer(question.id, with: "Straighten them")
            }
            if case .awaitingApproval = event {
                #expect(await library.rotations.isEmpty)
                await agent.approve()
            }
        }
        #expect(events.batchQuestions.count == (mode == .autonomous ? 0 : 1))
        #expect(await library.rotations.count == 3)
        let answer = try #require(try batchTestSummary(events).answers.first)
        #expect(answer.answer == "Straighten them")
        #expect(answer.byPerson == (mode != .autonomous))
    }

    @Test func mildTiltsRecommendLeavingThemAndNoTiltNeedsNoQuestion() async throws {
        let library = BatchTestLibrary([batchTestFacts(tilt: 0.5), batchTestFacts(tilt: 0.8), batchTestFacts(tilt: 2)])
        let events = try await batchTestCollect(await batchTestAgent(library).run(
            BatchOptions(mode: .autonomous, auto: false, qualityThreshold: 0)))
        let answer = try #require(try batchTestSummary(events).answers.first)
        #expect(answer.question.recommended == 1)
        #expect(answer.answer == "Leave them")
        #expect(!answer.byPerson)
        #expect(await library.rotations.isEmpty)
        let level = BatchTestLibrary([batchTestFacts(tilt: 0.4), batchTestFacts()])
        let noQuestion = try await batchTestCollect(await batchTestAgent(level).run(BatchOptions(auto: false)))
        #expect(noQuestion.batchQuestions.isEmpty)
    }

    @Test func personCanLeaveStrongTiltsAlone() async throws {
        let library = BatchTestLibrary([batchTestFacts(tilt: 4)])
        let agent = batchTestAgent(library)
        var events: [BatchEvent] = []
        for try await event in await agent.run(BatchOptions(auto: false)) {
            events.append(event)
            if case .question(let question) = event { await agent.answer(question.id, with: "Leave them") }
        }
        #expect(await library.rotations.isEmpty)
        #expect(try batchTestSummary(events).answers.first?.byPerson == true)
    }

    @Test func onlyLowQualityPhotosGetACloserLook() async throws {
        let low = PhotoID("photo-0")
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(), batchTestFacts()])
        let planner = BatchTestPlanner()
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(low, quality: 0.49), batchTestReview(PhotoID("photo-1"), quality: 0.5)])
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer, planner: planner).run(
            BatchOptions(mode: .autonomous, auto: false, straighten: false)))
        #expect(events.batchEdits == [low])
        #expect(await planner.plans.map(\.instruction) == [
            "Improve this photo naturally: fix exposure, colour and contrast where they are off, and nothing else.",
        ])
        #expect(await library.saved == [low])
        #expect(try batchTestSummary(events).photos[0].outcome == "Looks natural.")
        #expect(try batchTestSummary(events).modelCalls == 3)
    }

    @Test func askModeWaitsAndReplansWithThePersonsAnswer() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(PhotoID("photo-1"), matches: false)])
        let planner = BatchTestPlanner()
        let agent = batchTestAgent(library, reviewer: reviewer, planner: planner)
        var events: [BatchEvent] = []
        for try await event in await agent.run(BatchOptions(instruction: "Make all shirts blue", auto: false, straighten: false)) {
            events.append(event)
            if case .question(let question) = event {
                #expect(await reviewer.planRequests.count == 1)
                #expect(await library.edited.isEmpty)
                await agent.answer("unknown", with: "Navy")
                await agent.answer(question.id, with: "Not an option")
                #expect(await reviewer.planRequests.count == 1)
                await agent.answer(question.id, with: "Sky blue")
            }
        }
        let requests = await reviewer.planRequests
        #expect(requests.count == 2)
        #expect(requests[0].answers.isEmpty)
        #expect(requests[1].answers == ["shirts": "Sky blue"])
        // The planner sees every kept photo and decides; here it plans only the one the reviewer matched.
        #expect(requests.allSatisfy { $0.reviews.map(\.photo) == [PhotoID("photo-0"), PhotoID("photo-1")] })
        #expect(await planner.plans.map(\.instruction) == ["Make the shirts Sky blue"])
        #expect(await library.saved == [PhotoID("photo-0")])
        let summary = try batchTestSummary(events)
        #expect(summary.answers.count == 1 && summary.answers[0].byPerson)
        #expect(summary.modelCalls == 5)
    }

    @Test func autonomousQuestionsRecordTheRecommendation() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let reviewer = BatchTestReviewer()
        let agent = batchTestAgent(library, reviewer: reviewer)
        await agent.answer("shirts", with: "Sky blue")
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Blue shirts", auto: false, straighten: false)))
        #expect(events.batchQuestions.isEmpty)
        let answer = try #require(try batchTestSummary(events).answers.first)
        #expect(answer.answer == "Navy")
        #expect(!answer.byPerson)
        #expect(await reviewer.planRequests.last?.answers == ["shirts": "Navy"])
    }

    @Test func planFirstWaitsBeforeAnyPhotoChangesAndEstimatesTheWork() async throws {
        let bad = PhotoID("photo-0")
        let low = PhotoID("photo-1")
        let other = PhotoID("photo-2")
        let library = BatchTestLibrary([batchTestFacts(tilt: 3), batchTestFacts(tilt: 2), batchTestFacts()])
        let reviewer = BatchTestReviewer(reviews: [batchTestReview(bad, misfire: true), batchTestReview(low, quality: 0.1)])
        let agent = batchTestAgent(library, reviewer: reviewer)
        var events: [BatchEvent] = []
        var approved = false
        for try await event in await agent.run(BatchOptions(mode: .planFirst, instruction: "Blue shirts", concurrency: 1)) {
            events.append(event)
            if !approved {
                #expect(await library.flags.isEmpty)
                #expect(await library.autos.isEmpty)
                #expect(await library.rotations.isEmpty)
                #expect(await library.edited.isEmpty)
                #expect(await library.saved.isEmpty)
            }
            if case .question(let question) = event { await agent.answer(question.id, with: question.options[question.recommended]) }
            if case .awaitingApproval(let plan, let estimate) = event {
                #expect(plan.questions.isEmpty)
                #expect(Set(plan.groups.flatMap(\.photos)) == [low, other])
                #expect(estimate == 15)
                approved = true
                await agent.approve()
            }
        }
        #expect(approved)
        #expect(Set(await library.autos) == [low, other])
        #expect(await library.flags.keys.contains(bad))
        #expect(events.batchEdits == [low, low, other])
        #expect(Set(await library.saved) == [low, other])
        #expect(try batchTestSummary(events).answers.count == 2)
    }

    @Test func earlyAnswersAndApprovalAreRemembered() async throws {
        let library = BatchTestLibrary([batchTestFacts(tilt: 2)])
        let reviewer = BatchTestReviewer()
        let agent = batchTestAgent(library, reviewer: reviewer)
        await agent.answer("straighten", with: "Leave them")
        await agent.answer("shirts", with: "Sky blue")
        await agent.answer("unknown", with: "Ignored")
        await agent.approve()
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .planFirst, instruction: "Blue shirts", auto: false)))
        #expect(await library.rotations.isEmpty)
        let summary = try batchTestSummary(events)
        #expect(summary.answers.map(\.answer) == ["Leave them", "Sky blue"])
        #expect(summary.answers.allSatisfy { $0.byPerson })
        #expect(await reviewer.planRequests.last?.answers == ["straighten": "Leave them", "shirts": "Sky blue"])
    }

    @Test func earlyAnswersDuringMeasurementAreRemembered() async throws {
        let gate = BatchTestGate()
        let library = BatchTestLibrary([batchTestFacts(tilt: 2)], factsGate: gate)
        let agent = batchTestAgent(library)
        let consumer = Task { try await batchTestCollect(await agent.run(BatchOptions(mode: .planFirst, auto: false))) }
        await gate.waitFor(1)
        await agent.answer("straighten", with: "Leave them")
        await agent.approve()
        await gate.release()
        let summary = try batchTestSummary(try await consumer.value)
        #expect(summary.answers.first?.answer == "Leave them")
        #expect(await library.rotations.isEmpty)
    }

    @Test func repeatedQuestionsStopAfterThreePlanningRounds() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let reviewer = BatchTestReviewer(repeatQuestions: true)
        let agent = batchTestAgent(library, reviewer: reviewer)
        var events: [BatchEvent] = []
        for try await event in await agent.run(BatchOptions(instruction: "Blue shirts", auto: false, straighten: false)) {
            events.append(event)
            if case .question(let question) = event { await agent.answer(question.id, with: "Sky blue") }
        }
        #expect(await reviewer.planRequests.count == 3)
        #expect(events.batchQuestions.count == 2)
        let summary = try batchTestSummary(events)
        #expect(summary.answers.map(\.byPerson) == [true, true, false])
        #expect(summary.answers.last?.answer == "Navy")
    }

    @Test func onePhotoFailureDoesNotStopTheOthersAndStillCountsTheFailedCall() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let planner = BatchTestPlanner(failingPlanAt: 1)
        let events = try await batchTestCollect(await batchTestAgent(library, planner: planner).run(
            BatchOptions(mode: .autonomous, instruction: "Warm the photo", auto: false, straighten: false, concurrency: 1)))
        let summary = try batchTestSummary(events)
        #expect(summary.photos[0].failed)
        #expect(summary.photos[0].outcome?.contains("Cannot edit this photo") == true)
        #expect(!summary.photos[1].failed)
        #expect(await library.saved == [PhotoID("photo-1")])
        #expect(summary.modelCalls == 3)
        #expect(events.batchProgress == [1, 2])
    }

    /// SAM found no shirts by one name and the revision went on to a result the critic accepted, yet the photo was
    /// marked failed in Studio's grid. A step that failed fails the photo only when its edit didn't recover.
    @Test func aStepThatFailedFailsThePhotoOnlyIfTheEditDidNotRecover() async throws {
        for (revisions, failed) in [(1, false), (9, true)] {
            let library = BatchTestLibrary([batchTestFacts()])
            let agent = batchTestAgent(library, planner: BatchTestPlanner(redraw: true, revisions: revisions),
                                       segmenter: BatchTestSegmenter(findsNothing: 1))
            let events = try await batchTestCollect(await agent.run(
                BatchOptions(mode: .autonomous, instruction: "Blue shirts", auto: false, straighten: false)))
            let summary = try batchTestSummary(events)
            #expect(summary.photos[0].failed == failed, "after \(revisions) revisions asked for")
            #expect(summary.photos[0].outcome?.contains("nothing was found") == true, "the skipped step is still noted")
        }
    }

    @Test func hostFailuresAreIsolatedAndChangedPhotosAreSaved() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts(), batchTestFacts(), batchTestFacts()],
                                       failingFacts: [PhotoID("photo-0")], failingAuto: [PhotoID("photo-1")], failingSave: [PhotoID("photo-2")])
        let events = try await batchTestCollect(await batchTestAgent(library).run(BatchOptions(straighten: false)))
        let summary = try batchTestSummary(events)
        #expect(summary.photos.map(\.failed) == [true, true, true, false])
        #expect(await library.saved == [PhotoID("photo-3")])
        #expect(Set(await library.autos) == [PhotoID("photo-2"), PhotoID("photo-3")])
        #expect(events.batchProgress == [1, 2, 3, 4])
    }

    @Test func measurementsAndEditsStayWithinThePhotoConcurrency() async throws {
        let factsGate = BatchTestGate()
        let editGate = BatchTestGate()
        let library = BatchTestLibrary(Array(repeating: batchTestFacts(), count: 7), factsGate: factsGate)
        let planner = BatchTestPlanner(gate: editGate)
        let agent = batchTestAgent(library, planner: planner)
        let consumer = Task { try await batchTestCollect(await agent.run(
            BatchOptions(mode: .autonomous, instruction: "Warm the photo", auto: false, straighten: false, concurrency: 2))) }
        await factsGate.waitFor(2)
        #expect(await library.measured.count == 2)
        #expect(await library.peakFacts == 2)
        await factsGate.release()
        await editGate.waitFor(2)
        #expect(await planner.plans.count == 2)
        #expect(await planner.peak == 2)
        await editGate.release()
        let events = try await consumer.value
        #expect(await planner.peak == 2)
        #expect(await planner.plans.count == 7)
        #expect(try batchTestSummary(events).photos.count == 7)
    }

    @Test func reviewUses512PixelThumbnailsInBatchesOfTwentyWithAtMostThreeCalls() async throws {
        let gate = BatchTestGate()
        let library = BatchTestLibrary(Array(repeating: batchTestFacts(), count: 81))
        let reviewer = BatchTestReviewer(gate: gate)
        let agent = batchTestAgent(library, reviewer: reviewer)
        let consumer = Task { try await batchTestCollect(await agent.run(BatchOptions(auto: false, straighten: false, concurrency: 8))) }
        await gate.waitFor(3)
        #expect(await reviewer.reviewRequests.count == 3)
        #expect(await reviewer.peak == 3)
        await gate.release()
        let summary = try batchTestSummary(try await consumer.value)
        let requests = await reviewer.reviewRequests
        #expect(requests.count == 5)
        #expect(requests.allSatisfy { $0.photos.count <= 20 })
        #expect(requests.flatMap(\.photos).count == 81)
        #expect(await library.thumbnails.allSatisfy { $0.edge == 512 })
        #expect(await reviewer.peak == 3)
        #expect(summary.modelCalls == 5)
    }

    @Test func callBudgetStopsNewPhotosAndCountsEveryModelInAnEdit() async throws {
        let library = BatchTestLibrary(Array(repeating: batchTestFacts(), count: 6))
        let planner = BatchTestPlanner(redraw: true)
        let segmenter = BatchTestSegmenter()
        let generator = BatchTestGenerator()
        let agent = batchTestAgent(library, planner: planner, segmenter: segmenter, generator: generator)
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Blue shirts", auto: false,
                                                                           straighten: false, concurrency: 1, maxModelCalls: 5)))
        let summary = try batchTestSummary(events)
        #expect(await planner.plans.count == 1)
        #expect(await planner.critiques.count == 1)
        #expect(await segmenter.requests.count == 2)
        #expect(await generator.requests.count == 1)
        #expect(events.batchEdits.count == 1)
        #expect(summary.modelCalls == 5)
        #expect(summary.photos.count == 6)
        #expect(summary.photos.dropFirst().allSatisfy { $0.outcome?.contains("limit reached") == true })
        #expect(events.batchTraces.filter { $0.model != nil }.count == 5)
    }

    @Test func concurrentPhotosReserveTheirEstimatesBeforeStarting() async throws {
        let gate = BatchTestGate()
        let library = BatchTestLibrary(Array(repeating: batchTestFacts(), count: 8))
        let planner = BatchTestPlanner(gate: gate, redraw: true)
        let agent = batchTestAgent(library, planner: planner)
        let consumer = Task { try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Blue shirts", auto: false,
                                                                                    straighten: false, concurrency: 4, maxModelCalls: 10))) }
        await gate.waitFor(2)
        #expect(await planner.plans.count == 2)
        await gate.release()
        let summary = try batchTestSummary(try await consumer.value)
        #expect(await planner.plans.count == 2)
        #expect(summary.modelCalls == 10)
        #expect(await library.saved.count == 2)
    }

    @Test func revisionsCannotExceedTheActualCallLimit() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let planner = BatchTestPlanner(redraw: true, revisions: 2)
        let events = try await batchTestCollect(await batchTestAgent(library, planner: planner).run(
            BatchOptions(mode: .autonomous, instruction: "Blue shirts", auto: false, straighten: false, maxModelCalls: 5)))
        let summary = try batchTestSummary(events)
        #expect(summary.modelCalls == 5)
        #expect(await planner.critiques.count == 1)
        #expect(events.batchTraces.filter { $0.model != nil }.count == 5)
        #expect(summary.photos[0].outcome?.contains("limit reached") == true)
        #expect(await library.saved == [PhotoID("photo-0")])
    }

    @Test func reviewAndPlanningUseTheSameCallBudget() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let reviewer = BatchTestReviewer()
        let planner = BatchTestPlanner()
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer, planner: planner).run(
            BatchOptions(mode: .autonomous, instruction: "Blue shirts", auto: false, straighten: false, maxModelCalls: 2)))
        let summary = try batchTestSummary(events)
        #expect(await reviewer.reviewRequests.count == 1)
        #expect(await reviewer.planRequests.count == 1)
        #expect(await planner.plans.isEmpty)
        #expect(summary.modelCalls == 2)
        #expect(summary.photos[0].outcome?.contains("limit reached") == true)
    }

    @Test func zeroBudgetMakesNoCalls() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let reviewer = BatchTestReviewer()
        let events = try await batchTestCollect(await batchTestAgent(library, reviewer: reviewer).run(
            BatchOptions(mode: .autonomous, instruction: "Blue shirts", straighten: false, maxModelCalls: 0)))
        #expect(await reviewer.reviewRequests.isEmpty)
        #expect(await reviewer.planRequests.isEmpty)
        #expect(await library.autos.isEmpty)
        #expect(try batchTestSummary(events).modelCalls == 0)
        #expect(try batchTestSummary(events).photos.count == 1)
    }

    @Test func cancellationStopsRunningPhotoAgentsAndDoesNotStartMorePhotos() async throws {
        let gate = BatchTestGate()
        let library = BatchTestLibrary(Array(repeating: batchTestFacts(), count: 8))
        let planner = BatchTestPlanner(gate: gate)
        let agent = batchTestAgent(library, planner: planner)
        let consumer = Task { try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Warm the photo", auto: false,
                                                                                    straighten: false, concurrency: 2))) }
        await gate.waitFor(2)
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("A cancelled batch must fail its stream.")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await library.edited.count == 2)
        #expect(await library.saved.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationUnblocksQuestionsAndApproval(approval: Bool) async throws {
        let library = BatchTestLibrary([batchTestFacts(tilt: approval ? nil : 2)])
        let agent = batchTestAgent(library)
        do {
            for try await event in await agent.run(BatchOptions(mode: .planFirst)) {
                if case .question = event { await agent.cancel() }
                if case .awaitingApproval = event { await agent.cancel() }
            }
            Issue.record("A cancelled decision must fail its stream.")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await library.autos.isEmpty)
        #expect(await library.rotations.isEmpty)
    }

    @Test func measurementsSupplyQualityAndOnlyClearMisfiresWithoutAReviewer() async throws {
        let library = BatchTestLibrary([
            batchTestFacts(sharpness: 0.049), batchTestFacts(exposure: 0.029), batchTestFacts(exposure: 0.971),
            batchTestFacts(sharpness: 0.05, exposure: 0.03), batchTestFacts(exposure: 0.97),
            batchTestFacts(sharpness: 0.1, exposure: 0.1), batchTestFacts(),
        ])
        let planner = BatchTestPlanner()
        let agent = batchTestAgent(library, planner: planner)
        let events = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Warm every photo", auto: false,
                                                                           straighten: false, concurrency: 1)))
        #expect(Set(await library.flags.keys) == [PhotoID("photo-0"), PhotoID("photo-1"), PhotoID("photo-2")])
        let measured = events.compactMap { if case .reviewed(let review) = $0 { review } else { nil } }
        #expect(abs(measured[5].quality - (0.1 + 0.2 + 1) / 3) < 0.000001)
        #expect(measured[3...].allSatisfy { !$0.misfire })
        let instructions = await planner.plans.map(\.instruction)
        #expect(instructions.filter { $0 == "Warm every photo" }.count == 4)
        #expect(instructions.filter { $0.hasPrefix("Improve this photo naturally") }.count == 2)
        #expect(await library.thumbnails.isEmpty)
        let summary = try batchTestSummary(events)
        #expect(summary.photos.count == 7)
        #expect(summary.duration >= 0)
    }

    @Test func unchangedPhotosAreNotSavedAndEmptyLibrariesFinish() async throws {
        let library = BatchTestLibrary([batchTestFacts()])
        let events = try await batchTestCollect(await batchTestAgent(library, planner: BatchTestPlanner(noChange: true)).run(
            BatchOptions(mode: .autonomous, instruction: "Keep it", auto: false, straighten: false)))
        #expect(await library.saved.isEmpty)
        #expect(try batchTestSummary(events).modelCalls == 2)
        let empty = BatchTestLibrary([])
        let emptyEvents = try await batchTestCollect(await batchTestAgent(empty).run(BatchOptions()))
        #expect(try batchTestSummary(emptyEvents).photos.isEmpty)
        #expect(try batchTestSummary(emptyEvents).modelCalls == 0)
    }
}
