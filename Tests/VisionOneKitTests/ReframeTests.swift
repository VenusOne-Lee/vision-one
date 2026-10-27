import XCTest
@testable import VisionOneKit

final class VideoFormatTests: XCTestCase {
    func testOutputSizes() {
        XCTAssertTrue(VideoFormat.landscape.outputSize(shortEdge: 1080) == (1920, 1080))
        XCTAssertTrue(VideoFormat.vertical.outputSize(shortEdge: 1080) == (1080, 1920))
        XCTAssertTrue(VideoFormat.square.outputSize(shortEdge: 1080) == (1080, 1080))
        XCTAssertTrue(VideoFormat.portrait.outputSize(shortEdge: 1080) == (1080, 1350))
        let odd = VideoFormat.vertical.outputSize(shortEdge: 721)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
    }

    func testNearestFormat() {
        XCTAssertEqual(VideoFormat.nearest(width: 2880, height: 1800), .landscape)
        XCTAssertEqual(VideoFormat.nearest(width: 1170, height: 2532), .vertical)
        XCTAssertEqual(VideoFormat.nearest(width: 1000, height: 1000), .square)
        XCTAssertEqual(VideoFormat.nearest(width: 0, height: 0), .landscape)
    }

    func testRectStaysInsideTheFrame() {
        let rect = NormalisedRect(centerX: 0.98, centerY: 0.5, width: 0.3, height: 1)
        XCTAssertEqual(rect.maxX, 1, accuracy: 1e-12)
        XCTAssertEqual(rect.x, 0.7, accuracy: 1e-12)
        XCTAssertEqual(rect.y, 0)
        let left = NormalisedRect(centerX: -1, centerY: 0.5, width: 0.3, height: 0.5)
        XCTAssertEqual(left.x, 0)
    }
}

final class ReframePlannerTests: XCTestCase {
    /// 16:9 source, 9:16 output: the crop is the full height and
    /// 9/16 ÷ 16/9 of the width.
    func testVerticalCropSize() {
        let size = ReframePlanner.cropSize(sourceAspect: 16.0 / 9.0, contentAspect: 9.0 / 16.0)
        XCTAssertEqual(size.height, 1)
        XCTAssertEqual(size.width, (9.0 / 16.0) / (16.0 / 9.0), accuracy: 1e-12)

        let wider = ReframePlanner.cropSize(sourceAspect: 9.0 / 16.0, contentAspect: 16.0 / 9.0)
        XCTAssertEqual(wider.width, 1)
        XCTAssertLessThan(wider.height, 1)

        let zoomed = ReframePlanner.cropSize(sourceAspect: 16.0 / 9.0, contentAspect: 1, zoom: 0.5)
        XCTAssertEqual(zoomed.height, 0.5)
    }

    func testSplitUsesTheScreenPane() {
        let aspect = ReframePlanner.contentAspect(format: .vertical, mode: .split)
        XCTAssertEqual(aspect, (9.0 / 16.0) / ReframePlan.splitScreenShare, accuracy: 1e-12)
    }

    func testFitShowsEverything() {
        let plan = ReframePlanner.plan(format: .vertical, mode: .fit, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 10, focus: [FocusPoint(t: 0, x: 0.9, y: 0.9)])
        XCTAssertEqual(plan.crop(at: 5), .full)
    }

    func testNothingToFollowStaysCentred() {
        let plan = ReframePlanner.plan(format: .vertical, mode: .follow, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 5, focus: [])
        XCTAssertEqual(plan.crop(at: 2.5).centerX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(plan.crop(at: 2.5).height, 1)
    }

    func testFollowsTheCursorAndKeepsItInFrame() {
        // Cursor parks on the left, then jumps to the right at 5 s.
        let focus = [FocusPoint(t: 0, x: 0.2, y: 0.5), FocusPoint(t: 5, x: 0.8, y: 0.5)]
        let plan = ReframePlanner.plan(format: .vertical, mode: .follow, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 10, focus: focus)
        let early = plan.crop(at: 2)
        let late = plan.crop(at: 9)
        XCTAssertTrue(early.x <= 0.2 && 0.2 <= early.maxX, "cursor on the left is in frame")
        XCTAssertTrue(late.x <= 0.8 && 0.8 <= late.maxX, "cursor on the right is in frame")
        for t in stride(from: 0.0, through: 10, by: 0.1) {
            let crop = plan.crop(at: t)
            XCTAssertGreaterThanOrEqual(crop.x, -1e-9)
            XCTAssertLessThanOrEqual(crop.maxX, 1 + 1e-9)
        }
    }

    func testLooksAheadSoItMovesBeforeTheCursor() {
        let focus = [FocusPoint(t: 0, x: 0.2, y: 0.5), FocusPoint(t: 5, x: 0.8, y: 0.5)]
        let plan = ReframePlanner.plan(format: .vertical, mode: .follow, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 10, focus: focus)
        XCTAssertGreaterThan(plan.crop(at: 4.9).centerX, plan.crop(at: 3).centerX + 0.01)
    }

    func testDeadZoneIgnoresSmallWobbles() {
        var focus: [FocusPoint] = []
        for i in 0..<100 {
            let t = Double(i) * 0.1
            focus.append(FocusPoint(t: t, x: 0.5 + (i.isMultiple(of: 2) ? 0.01 : -0.01), y: 0.5))
        }
        let plan = ReframePlanner.plan(format: .vertical, mode: .follow, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 10, focus: focus)
        let xs = stride(from: 0.0, through: 10, by: 0.1).map { plan.crop(at: $0).centerX }
        XCTAssertLessThan((xs.max() ?? 0) - (xs.min() ?? 0), 0.005)
    }

    func testSpeedIsLimited() {
        var options = ReframePlanner.Options()
        options.smoothing = 0
        options.lookAhead = 0
        let focus = [FocusPoint(t: 0, x: 0.1, y: 0.5), FocusPoint(t: 1, x: 0.9, y: 0.5)]
        let plan = ReframePlanner.plan(format: .vertical, mode: .follow, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 4, focus: focus, options: options)
        let width = plan.cropWidth
        for i in 1..<plan.keyframes.count {
            let a = plan.keyframes[i - 1], b = plan.keyframes[i]
            let speed = abs(b.x - a.x) / (b.t - a.t)
            XCTAssertLessThanOrEqual(speed, options.maxSpeed * width + 1e-9)
        }
    }

    func testPinsWin() {
        var plan = ReframePlanner.plan(format: .square, mode: .follow, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 10, focus: [FocusPoint(t: 0, x: 0.9, y: 0.5)])
        plan.pin(centerX: 0.3, centerY: 0.5, from: 2, to: 4)
        XCTAssertEqual(plan.crop(at: 3).centerX, 0.3, accuracy: 1e-9)
        XCTAssertGreaterThan(plan.crop(at: 6).centerX, 0.5)

        // A new pin over the same stretch replaces the old one.
        plan.pin(centerX: 0.4, centerY: 0.5, from: 3, to: 5)
        XCTAssertEqual(plan.pins.count, 1)
        XCTAssertEqual(plan.crop(at: 2.5).centerX, plan.crop(at: 7).centerX, accuracy: 0.2)

        plan.unpin(at: 4)
        XCTAssertTrue(plan.pins.isEmpty)
    }

    func testPlanRoundTripsAsJSON() throws {
        var plan = ReframePlanner.plan(format: .vertical, mode: .split, sourceWidth: 1920, sourceHeight: 1080,
                                       duration: 2, focus: [FocusPoint(t: 0, x: 0.3, y: 0.3)])
        plan.pin(centerX: 0.5, centerY: 0.5, from: 0, to: 1)
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(ReframePlan.self, from: data), plan)
    }

    func testFocusFromEventsIgnoresTheCursorOutsideTheCapture() {
        var log = EventLog(displayWidth: 1000, displayHeight: 500)
        log.append(InputEvent(kind: .move, t: 0, x: 250, y: 250))
        log.append(InputEvent(kind: .leftDown, t: 1, x: 900, y: 100))
        let whole = ReframePlanner.focus(from: log)
        XCTAssertEqual(whole.count, 2)
        XCTAssertEqual(whole[0].x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(whole[1].y, 0.2, accuracy: 1e-12)

        // Recording only the left half of the display.
        let half = ReframePlanner.focus(from: log, capture: NormalisedRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(half.count, 1)
        XCTAssertEqual(half[0].x, 0.5, accuracy: 1e-12)
    }
}
