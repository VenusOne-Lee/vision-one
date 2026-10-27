import XCTest
@testable import VisionOneKit

final class TimelineScaleTests: XCTestCase {
    func testStepKeepsLabelsApart() {
        // A 37 s take across 900 points: about 24 pt a second.
        XCTAssertEqual(TimelineScale.step(pointsPerSecond: 900 / 37.0), 5)
        XCTAssertEqual(TimelineScale.step(pointsPerSecond: 200), 0.5)
        XCTAssertEqual(TimelineScale.step(pointsPerSecond: 1000), 0.1)
        // An hour across 900 points.
        XCTAssertEqual(TimelineScale.step(pointsPerSecond: 0.25), 300)
        XCTAssertEqual(TimelineScale.step(pointsPerSecond: 0), 3600)
    }

    func testLabels() {
        XCTAssertEqual(TimelineScale.label(12, step: 5), "0:12")
        XCTAssertEqual(TimelineScale.label(3723, step: 60), "1:02:03")
        XCTAssertEqual(TimelineScale.label(3.5, step: 0.5), "0:03.5")
        XCTAssertEqual(TimelineScale.label(3.25, step: 0.25), "0:03.25")
    }

    func testTicks() {
        XCTAssertEqual(TimelineScale.ticks(from: 0, to: 12, step: 5), [0, 5, 10])
        XCTAssertEqual(TimelineScale.ticks(from: 7, to: 21, step: 5), [5, 10, 15, 20])
        XCTAssertTrue(TimelineScale.ticks(from: 0, to: 10, step: 0).isEmpty)
    }

    func testZoomLimits() {
        XCTAssertEqual(TimelineScale.clampZoom(0.5, duration: 37, width: 900), 1)
        XCTAssertEqual(TimelineScale.clampZoom(100, duration: 37, width: 900), 37 * 200 / 900.0, accuracy: 1e-9)
        // A take shorter than the closest zoom can't zoom at all.
        XCTAssertEqual(TimelineScale.clampZoom(4, duration: 2, width: 900), 1)
    }

    func testZoomKeepsTheMomentInPlace() {
        // 30 s at 600 pt, zoom 4: the content is 2400 pt; 15 s is at 1200.
        XCTAssertEqual(TimelineScale.offset(keeping: 15, atViewX: 300, zoom: 4, duration: 30, width: 600), 900)
        XCTAssertEqual(TimelineScale.offset(keeping: 0, atViewX: 300, zoom: 4, duration: 30, width: 600), 0)
        XCTAssertEqual(TimelineScale.offset(keeping: 30, atViewX: 0, zoom: 4, duration: 30, width: 600), 1800)
    }

    func testPreciseTimecode() {
        XCTAssertEqual(Timecode.precise(from: 12.34), "00:00:12.10")
        XCTAssertEqual(Timecode.precise(from: 0), "00:00:00.00")
        XCTAssertEqual(Timecode.precise(from: 59.999), "00:01:00.00")
    }
}

final class TimelineZoomCapTests: XCTestCase {
    func testLongTakesStopAtTheWidestTimeline() {
        XCTAssertEqual(TimelineScale.clampZoom(1000, duration: 3600, width: 1000), 20, accuracy: 1e-9)
    }
}
