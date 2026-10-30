import XCTest
@testable import VisionOneKit

final class ClipFollowTests: XCTestCase {
    func testFollowMovesOverSourceClockWhileFixedAndFitRemainManual() throws {
        let log = EventLog(displayWidth: 1920, displayHeight: 1080, events: [
            InputEvent(kind: .leftDown, t: 0, x: 200, y: 540),
            InputEvent(kind: .move, t: 2, x: 250, y: 540),
            InputEvent(kind: .leftDown, t: 8, x: 1700, y: 540),
            InputEvent(kind: .move, t: 10, x: 1700, y: 540),
        ])
        let plan = try XCTUnwrap(ClipFrame.reframe(format: .vertical, framing: .follow,
            sourceWidth: 1920, sourceHeight: 1080, duration: 12, events: log))
        XCTAssertLessThan(plan.crop(at: 0).centerX, plan.crop(at: 10).centerX)
        XCTAssertGreaterThanOrEqual(plan.crop(at: 0).x, 0)
        XCTAssertLessThanOrEqual(plan.crop(at: 10).maxX, 1)
        for mode in [ClipFraming.Mode.fixed, .fit] {
            XCTAssertNil(ClipFrame.reframe(format: .vertical, framing: ClipFraming(mode: mode),
                sourceWidth: 1920, sourceHeight: 1080, duration: 12, events: log))
        }
    }
}
