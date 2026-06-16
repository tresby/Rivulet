import XCTest
import CoreGraphics
@testable import Rivulet

@MainActor
final class AetherSubtitleModelTests: XCTestCase {

    // MARK: - Helpers

    // Cue fixture: id0 is active 1...5, id1 is active 6...10
    private func makeCues() -> [AetherSubtitleCue] {
        [
            AetherSubtitleCue(id: 0, startTime: 1, endTime: 5, body: .text("cue0")),
            AetherSubtitleCue(id: 1, startTime: 6, endTime: 10, body: .text("cue1")),
        ]
    }

    private func make1x1Image() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
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
        // delaySeconds=2 at sourceTime=7 -> effective lookup = 5, which is
        // cue0's endTime (inclusive), so cue0 is active.
        let model = AetherSubtitleModel()
        model.update(cues: makeCues())
        model.delaySeconds = 2
        model.sourceTime = 7
        XCTAssertEqual(model.activeCues.map(\.id), [0])
    }

    // MARK: - bitmap cues

    func testActiveCues_returnsBitmapCue() {
        // Bitmap (PGS/DVB) cues must flow through the model just like text.
        let model = AetherSubtitleModel()
        let img = make1x1Image()
        model.update(cues: [
            AetherSubtitleCue(
                id: 7, startTime: 1, endTime: 5,
                body: .image(cgImage: img, position: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1))
            )
        ])
        model.sourceTime = 3
        let active = model.activeCues
        XCTAssertEqual(active.map(\.id), [7])
        if case .image(_, let position) = active.first?.body {
            XCTAssertEqual(position.minX, 0.1, accuracy: 0.0001)
        } else {
            XCTFail("expected an image body")
        }
    }

    // MARK: - maxCueDuration

    func testMaxCueDuration_computedFromCues() {
        let model = AetherSubtitleModel()
        // cue durations 4 and 4 -> max 4, clamped to minimum 6
        model.update(cues: makeCues())
        XCTAssertEqual(model.maxCueDuration, 6, "should clamp to minimum 6")
    }

    func testMaxCueDuration_reflectsLongerCue() {
        let model = AetherSubtitleModel()
        let longCue = AetherSubtitleCue(id: 0, startTime: 0, endTime: 10, body: .text("long"))
        model.update(cues: [longCue])
        XCTAssertEqual(model.maxCueDuration, 10, "should reflect the actual long cue")
    }
}
