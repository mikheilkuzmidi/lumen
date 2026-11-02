import Foundation
import Testing
@testable import LumenCore

@Suite("Batch cancellation snapshots", .timeLimit(.minutes(1)))
struct BatchSnapshotTests {
    @Test func cancellationAtApprovalKeepsEveryPhotoUnfinishedWithoutAFinishedEvent() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let agent = batchTestAgent(library)
        var reported: BatchSnapshot?
        var finished = false
        do {
            for try await event in await agent.run(BatchOptions(mode: .planFirst, straighten: false)) {
                if case .finished = event { finished = true }
                if case .awaitingApproval = event { reported = await agent.cancelAndWait() }
            }
            Issue.record("The stream must still report cancellation.")
        } catch { #expect(error as? LumenError == .cancelled) }
        let snapshot = try #require(reported)
        #expect(snapshot.cancelled && snapshot.settled)
        #expect(snapshot.completedPhotoIDs.isEmpty)
        #expect(snapshot.unfinishedPhotoIDs == [PhotoID("photo-0"), PhotoID("photo-1")])
        #expect(snapshot.summary.photos.count == 2)
        #expect(await agent.snapshot() == snapshot)
        #expect(!finished)
        #expect(await library.autos.isEmpty)
        #expect(await library.saved.isEmpty)
    }

    @Test func aSavedPhotoIsCompletedWhileAnInterruptedSaveAndLaterPhotosAreUnfinished() async throws {
        let photos = [PhotoID("photo-0"), PhotoID("photo-1"), PhotoID("photo-2")]
        let library = BatchTestLibrary(Array(repeating: batchTestFacts(), count: 3))
        let gate = BatchTestGate()
        let host = SnapshotSavingLibrary(base: library, gatedPhoto: photos[1], gate: gate)
        let agent = BatchAgent(host: host, reviewer: nil, planner: BatchTestPlanner(), segmenter: BatchTestSegmenter(),
                               generator: BatchTestGenerator())
        let consumer = Task {
            try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, straighten: false, qualityThreshold: 0, concurrency: 1)))
        }
        await gate.waitFor(1)
        let live = try #require(await agent.snapshot())
        #expect(!live.settled && !live.cancelled)
        #expect(live.completedPhotoIDs == [photos[0]])
        #expect(live.unfinishedPhotoIDs == [photos[1], photos[2]])
        await agent.cancel()
        await gate.release()
        let stopped = try #require(await agent.cancelAndWait())
        await #expect(throws: LumenError.cancelled) { try await consumer.value }
        #expect(stopped.cancelled && stopped.settled)
        #expect(stopped.completedPhotoIDs == [photos[0]])
        #expect(stopped.unfinishedPhotoIDs == [photos[1], photos[2]])
        #expect(await library.saved == [photos[0]])
        #expect(await agent.snapshot() == stopped)
    }

    @Test func cancelledModelAttemptsRemainCountedEvenWhenTheirFinalTraceWasNotDelivered() async throws {
        let gate = BatchTestGate()
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let agent = batchTestAgent(library, planner: BatchTestPlanner(gate: gate))
        let consumer = Task {
            try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Warm it", auto: false,
                                                                   straighten: false, qualityThreshold: 0, concurrency: 1)))
        }
        await gate.waitFor(1)
        let live = try #require(await agent.snapshot())
        #expect(live.startedModelCalls == 1)
        #expect(live.summary.modelCalls == 0)
        await agent.cancel()
        await gate.release()
        let stopped = try #require(await agent.cancelAndWait())
        await #expect(throws: LumenError.cancelled) { try await consumer.value }
        #expect(stopped.startedModelCalls == 1)
        #expect(stopped.startedModelCalls >= stopped.summary.modelCalls)
        #expect(stopped.unfinishedPhotoIDs.count == 2)
        #expect(await library.saved.isEmpty)
    }

    @Test func finalSnapshotSeparatesCompletedExcludedFlaggedAndFailedAndSurvivesFinish() async throws {
        let photos = (0..<4).map { PhotoID("photo-\($0)") }
        let library = BatchTestLibrary([batchTestFacts(sharpness: 0.01), batchTestFacts(), batchTestFacts(), batchTestFacts()],
                                       failingFacts: [photos[3]])
        let agent = batchTestAgent(library)
        let stream = await agent.run(BatchOptions(mode: .planFirst, straighten: false, qualityThreshold: 0))
        var events: [BatchEvent] = []
        for try await event in stream {
            events.append(event)
            if case .awaitingApproval(let plan, _) = event {
                try await agent.approve(BatchApproval(approvalToken: try #require(plan.approvalToken), excludedPhotoIDs: [photos[1]]))
            }
        }
        let snapshot = try #require(await agent.snapshot())
        #expect(snapshot.settled && !snapshot.cancelled)
        #expect(snapshot.completedPhotoIDs == [photos[2]])
        #expect(snapshot.excludedPhotoIDs == [photos[1]])
        #expect(snapshot.flaggedPhotoIDs == [photos[0]])
        #expect(snapshot.failedPhotoIDs == [photos[3]])
        #expect(snapshot.skippedPhotoIDs.isEmpty && snapshot.unfinishedPhotoIDs.isEmpty)
        #expect(snapshot.summary.photos == (try batchTestSummary(events)).photos)
        #expect(await agent.cancelAndWait() == snapshot)
        #expect(try JSONDecoder().decode(BatchSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test func modelBudgetSkipsAreNotReportedAsCompleted() async throws {
        let library = BatchTestLibrary([batchTestFacts(), batchTestFacts()])
        let agent = batchTestAgent(library)
        _ = try await batchTestCollect(await agent.run(BatchOptions(mode: .autonomous, instruction: "Warm it", auto: false,
                                                                  straighten: false, qualityThreshold: 0, maxModelCalls: 0)))
        let snapshot = try #require(await agent.snapshot())
        #expect(snapshot.completedPhotoIDs.isEmpty)
        #expect(snapshot.skippedPhotoIDs == [PhotoID("photo-0"), PhotoID("photo-1")])
        #expect(snapshot.unfinishedPhotoIDs.isEmpty)
        #expect(snapshot.startedModelCalls == 0)
    }
}

private struct SnapshotSavingLibrary: LibraryHost {
    let base: BatchTestLibrary
    let gatedPhoto: PhotoID
    let gate: BatchTestGate
    func photos() async throws -> [PhotoID] { try await base.photos() }
    func thumbnail(_ photo: PhotoID, maxLongEdge: Int) async throws -> EncodedImage { try await base.thumbnail(photo, maxLongEdge: maxLongEdge) }
    func facts(_ photo: PhotoID) async throws -> PhotoFacts { try await base.facts(photo) }
    func applyAuto(_ photo: PhotoID) async throws -> String { try await base.applyAuto(photo) }
    func straighten(_ photo: PhotoID, degrees: Double) async throws { try await base.straighten(photo, degrees: degrees) }
    func flag(_ photo: PhotoID, reason: String) async throws { try await base.flag(photo, reason: reason) }
    func editHost(_ photo: PhotoID) async throws -> any EditHost { try await base.editHost(photo) }
    func save(_ photo: PhotoID) async throws {
        if photo == gatedPhoto { await gate.enter() }
        try Task.checkCancellation()
        try await base.save(photo)
    }
}
