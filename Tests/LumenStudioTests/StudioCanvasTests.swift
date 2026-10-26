import Testing
@testable import LumenStudio

struct StudioCanvasTests {
    @Test func selectionFramesRevealSmoothlyAndSettle() {
        let start = StudioSelectionFrame(elapsed: 0, reduceMotion: false)
        let snapshot = StudioSelectionFrame(elapsed: 0.6, reduceMotion: false)
        let settled = StudioSelectionFrame(elapsed: 3, reduceMotion: false)
        #expect(start.drawn == 0 && start.tint == 0)
        #expect(snapshot.drawn == 1 && snapshot.tint > 0.1)
        #expect(snapshot.shimmer > -0.6 && snapshot.shimmer < 1.3)
        #expect(abs(settled.tint - 0.1) < 0.0001)
        let reduced = StudioSelectionFrame(elapsed: 0, reduceMotion: true)
        #expect(reduced.drawn == 1 && reduced.tint == 0.12)
    }
}
