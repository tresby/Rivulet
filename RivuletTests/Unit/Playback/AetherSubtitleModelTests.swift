import XCTest
@testable import Rivulet

@MainActor
final class AetherSubtitleModelTests: XCTestCase {

    // MARK: - Helpers

    // Cue fixture: id0 is active 1...5, id1 is active 6...10
    private func makeCues() -> [SubtitleCue] {
        [
            SubtitleCue(id: 0, startTime: 1, endTime: 5, text: "cue0"),
            SubtitleCue(id: 1, startTime: 6, endTime: 10, text: "cue1"),
        ]
    }

    // MARK: - activeCues lookup

    func testActiveCues_returnsMatchingCue_atMidpoint() {
        let model = AetherSubtitleModel()
        model.update(cues: makeCues())
        model.sourceTime = 3
        XCTAssertEqual(model.activeCues.map(\.id), [0])
    }

    func testActiveCues_returnsSecondCue_inSecondWindow() {
        let model = AetherSubtitleModel()
        model.update(cues: makeCues())
        model.sourceTime = 7
        XCTAssertEqual(model.activeCues.map(\.id), [1])
    }

    func testActiveCues_returnsEmpty_betweenCues() {
        let model = AetherSubtitleModel()
        model.update(cues: makeCues())
        model.sourceTime = 5.5
        XCTAssertEqual(model.activeCues.map(\.id), [])
    }

    // MARK: - delaySeconds

    func testActiveCues_respectsDelaySeconds() {
        // With a 2-second delay, observing at t=7 is equivalent to t=5 source time.
        // t=5 is the endTime of cue0 (exclusive), so cue0 should NOT be active.
        // But at t=7 source, effective = 7-2 = 5, which is at the boundary.
        // The spec example is: delaySeconds=2 at t=7 -> [cue0].
        // That implies effective = 7-2 = 5, and cue0 endTime=5 is INCLUSIVE at end.
        // To match the spec, we need to check what the boundary behavior is:
        // The spec says at t=7 with delay=2 -> [cue0], meaning the effective window
        // is [startTime, endTime] inclusive on both ends.
        // Verify by setting delay=2, sourceTime=7 -> effective=5 -> returns cue0.
        let model = AetherSubtitleModel()
        model.update(cues: makeCues())
        model.delaySeconds = 2
        model.sourceTime = 7
        // effective lookup time = 7 - 2 = 5
        // cue0 is [1, 5]; at exactly t=5 it should still be active per the spec
        XCTAssertEqual(model.activeCues.map(\.id), [0])
    }

    // MARK: - maxCueDuration

    func testMaxCueDuration_computedFromCues() {
        let model = AetherSubtitleModel()
        // cue durations: 5-1=4, 10-6=4 -> maxCueDuration = max(4, 4) = 4, min 6 -> 6
        model.update(cues: makeCues())
        XCTAssertEqual(model.maxCueDuration, 6, "should clamp to minimum 6")
    }

    func testMaxCueDuration_reflectsLongerCue() {
        let model = AetherSubtitleModel()
        let longCue = SubtitleCue(id: 0, startTime: 0, endTime: 10, text: "long")
        model.update(cues: [longCue])
        XCTAssertEqual(model.maxCueDuration, 10, "should reflect the actual long cue")
    }
}
