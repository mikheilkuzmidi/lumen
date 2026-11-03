import Foundation
import LumenCore
import Testing
@testable import LumenStudio

@Suite("Studio library outcomes")
@MainActor
struct StudioLibraryOutcomeTests {
    @Test func mixedFailureIsClearlyDifferentFromSuccessfulCompletion() {
        let model = StudioLibraryModel()
        let mixed = BatchSummary(photos: [
            BatchPhotoResult(photo: PhotoID("done")),
            BatchPhotoResult(photo: PhotoID("rejected"), outcome: "Revision limit reached. Edge still visible.", failed: true),
            BatchPhotoResult(photo: PhotoID("excluded"), outcome: "Skipped: excluded from the approved plan."),
        ], answers: [], modelCalls: 4, duration: 1)
        model.receive(.finished(mixed))
        #expect(model.summary == mixed)
        #expect(model.completionDetail == "1 completed · 1 excluded · 1 failed")
        #expect(model.status == "Finished with issues · 1 completed · 1 excluded · 1 failed")
        #expect(model.events.last?.symbol == "exclamationmark.triangle")
        #expect(model.events.last?.status.label == "Needs attention")
        model.receive(.editFinished(BatchPhotoResult(photo: PhotoID("rejected"), outcome: "Edge still visible.", failed: true)))
        #expect(model.events.last?.title == "Needs attention · rejected")
        #expect(model.events.last?.status == .failed("Edge still visible."))

        let success = BatchSummary(photos: [BatchPhotoResult(photo: PhotoID("done"))], answers: [], modelCalls: 2, duration: 1)
        model.receive(.finished(success))
        #expect(model.status == "Finished · 1 completed")
        #expect(model.events.last?.symbol == "checkmark.seal")
        #expect(model.events.last?.status == .done)
    }
}
