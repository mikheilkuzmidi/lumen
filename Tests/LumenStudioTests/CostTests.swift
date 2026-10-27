import Foundation
import LumenCore
import Testing
@testable import LumenStudio

@MainActor
struct CostTests {
    @Test func libraryRunningTotalSurvivesTimelineTrimmingAndMatchesSummary() {
        let model = StudioLibraryModel()
        let trace = TraceEvent(kind: .plan, model: "planner", detail: "Plan", started: Date(), duration: 0, cost: 0.01)
        for _ in 0..<90 { model.receive(.trace(trace)) }
        model.receive(.edit(PhotoID("photo"), .trace(trace)))
        #expect(model.modelCalls == 91)
        #expect(abs(model.totalCost - 0.91) < 0.00000001)
        #expect(model.events.count == 80)
        #expect(model.timelineText.contains("Cost: $0.9100 USD"))
        let summary = BatchSummary(photos: [], answers: [], modelCalls: 91, duration: 0, events: Array(repeating: trace, count: 91))
        model.receive(.finished(summary))
        #expect(model.totalCost == summary.totalCost)
    }

    @Test func approvalLabelsItsDollarAmountAsAnEstimate() {
        let model = StudioLibraryModel()
        let plan = BatchPlan(summary: "Blue shirts", groups: [], estimatedCost: 0.62)
        model.receive(.awaitingApproval(plan, estimatedModelCalls: 100))
        #expect(model.events.last?.detail == "About 100 more model calls, about $0.62 USD")
    }

    @Test func photoTimelineSumsEachCallAndExportsItsTotal() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let photo = try LibraryTestPhoto(url: fixture.folder.appendingPathComponent(fixture.photos[0].rawValue))
        let model = StudioModel(makePhoto: { _ in photo })
        let host = StudioPhotoHost(photo: photo)
        let trace = TraceEvent(kind: .plan, model: "planner", detail: "Plan", started: Date(), duration: 0, cost: 0.01)
        try await model.openLibraryPhoto(fixture.folder.appendingPathComponent(fixture.photos[0].rawValue), host: host,
                                         events: [.trace(trace), .trace(trace)])
        #expect(model.modelCalls == 2)
        #expect(model.totalCost == 0.02)
        #expect(model.timelineText.contains("Cost: $0.0200 USD"))
    }
}
