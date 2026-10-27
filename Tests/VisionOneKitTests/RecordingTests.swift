import XCTest
@testable import VisionOneKit

final class PauseLogTests: XCTestCase {
    func testPausedTimeIsCountedIncludingARunningPause() {
        var log = PauseLog()
        log.pause(at: 10)
        log.resume(at: 14)
        log.pause(at: 20)
        XCTAssertTrue(log.isPaused)
        XCTAssertEqual(log.pausedDuration(at: 23), 7, accuracy: 0.0001)
        log.resume(at: 25)
        XCTAssertEqual(log.pausedDuration(at: 100), 9, accuracy: 0.0001)
    }

    func testPauseAndResumeTwiceDoNothing() {
        var log = PauseLog()
        log.pause(at: 5)
        log.pause(at: 7)
        log.resume(at: 9)
        log.resume(at: 12)
        XCTAssertEqual(log.spans, [TimeSpan(start: 5, end: 9)])
    }

    func testPausesBecomeAcceptedCutsFromTheFirstFrame() {
        var log = PauseLog()
        log.pause(at: 105)
        log.resume(at: 110)
        log.pause(at: 130)
        let cuts = log.cuts(firstFrame: 100, end: 140)
        XCTAssertEqual(cuts.map(\.span), [TimeSpan(start: 5, end: 10), TimeSpan(start: 30, end: 40)])
        XCTAssertTrue(cuts.allSatisfy { $0.state == .accepted && $0.reason == Cut.Reason.paused })
    }

    func testPauseBeforeTheFirstFrameIsClipped() {
        var log = PauseLog()
        log.pause(at: 98)
        log.resume(at: 99)
        log.pause(at: 99.5)
        log.resume(at: 102)
        let cuts = log.cuts(firstFrame: 100, end: 120)
        XCTAssertEqual(cuts.map(\.span), [TimeSpan(start: 0, end: 2)])
    }

    func testPausesAreLeftOutOfTheVideo() {
        var edits = EditList(sourceDuration: 60)
        for cut in PauseLog.closed([TimeSpan(start: 105, end: 110)]).cuts(firstFrame: 100, end: 160) {
            edits.add(cut)
        }
        edits.add(Cut(span: TimeSpan(start: 20, end: 21)))
        XCTAssertEqual(edits.keptSpans.count, 3)
    }

    func testCountdownFallsBackToThreeSeconds() {
        XCTAssertEqual(CountdownLength(saved: nil), .three)
        XCTAssertEqual(CountdownLength(saved: 7), .three)
        XCTAssertEqual(CountdownLength(saved: 0), .off)
        XCTAssertEqual(CountdownLength(saved: 5).title, "5 s")
    }
}

private extension PauseLog {
    static func closed(_ spans: [TimeSpan]) -> PauseLog {
        var log = PauseLog()
        for span in spans {
            log.pause(at: span.start)
            log.resume(at: span.end)
        }
        return log
    }
}

final class MicLevelMeterTests: XCTestCase {
    func testLoudSpeechLightsTheMeterAndFallsBackSlowly() {
        var meter = MicLevelMeter()
        meter.update(peak: 1, at: 0)
        XCTAssertEqual(meter.level, 1, accuracy: 0.0001)
        XCTAssertEqual(meter.litBars(of: 5), 5)
        // Half a second of silence falls 12 dB, not to the floor.
        meter.update(peak: 0, at: 0.5)
        XCTAssertEqual(meter.level, 48.0 / 60.0, accuracy: 0.0001)
        meter.update(peak: 0, at: 10)
        XCTAssertEqual(meter.litBars(of: 5), 0)
    }

    func testSilenceWarningAfterSixQuietSeconds() {
        var meter = MicLevelMeter()
        meter.update(peak: 0.0005, at: 0) // about -66 dBFS: room noise
        meter.update(peak: 0.0005, at: 5)
        XCTAssertFalse(meter.isSilent(at: 5))
        meter.update(peak: 0.0005, at: 6.5)
        XCTAssertTrue(meter.isSilent(at: 6.5))
        meter.update(peak: 0.2, at: 7) // speech
        XCTAssertFalse(meter.isSilent(at: 7))
        XCTAssertTrue(meter.isSilent(at: 13))
    }

    func testRestartingTheTimerHoldsTheWarningBack() {
        var meter = MicLevelMeter()
        meter.update(peak: 0, at: 0)
        XCTAssertTrue(meter.isSilent(at: 8))
        meter.restartSilenceTimer(at: 8)
        XCTAssertFalse(meter.isSilent(at: 10))
    }

    func testDecibelsAndPeaks() {
        XCTAssertEqual(MicLevelMeter.decibels(1), 0, accuracy: 0.0001)
        XCTAssertEqual(MicLevelMeter.decibels(0.1), -20, accuracy: 0.0001)
        XCTAssertEqual(MicLevelMeter.decibels(0), -60)
        let floats: [Float] = [0.1, -0.5, 0.25]
        floats.withUnsafeBufferPointer { XCTAssertEqual(MicLevelMeter.peak(ofFloats: $0), 0.5, accuracy: 0.0001) }
        let ints: [Int16] = [0, Int16.min, 100]
        ints.withUnsafeBufferPointer { XCTAssertEqual(MicLevelMeter.peak(ofInt16: $0), 1, accuracy: 0.0001) }
    }
}

final class AreaShapeTests: XCTestCase {
    let screen = CaptureRect(x: 0, y: 0, width: 1600, height: 1000)

    private func assertClose(_ a: CaptureRect, _ b: CaptureRect, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.x, b.x), (a.y, b.y), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 0.001, "\(a) is not \(b)", file: file, line: line)
        }
    }

    func testFittedKeepsTheBiggestCentredBox() {
        let drawn = CaptureRect(x: 100, y: 100, width: 800, height: 800)
        assertClose(drawn.fitted(ratio: 16.0 / 9.0), CaptureRect(x: 100, y: 275, width: 800, height: 450))
        assertClose(drawn.fitted(ratio: 9.0 / 16.0), CaptureRect(x: 275, y: 100, width: 450, height: 800))
        assertClose(drawn.fitted(ratio: 1), drawn)
    }

    func testCornerResizeKeepsTheShapeAndTheOppositeCorner() {
        let rect = CaptureRect(x: 100, y: 100, width: 320, height: 180)
        let out = rect.resized([.right, .bottom], dx: 160, dy: 0, within: screen, keeping: 16.0 / 9.0)
        assertClose(out, CaptureRect(x: 100, y: 100, width: 480, height: 270))
        let topLeft = rect.resized([.left, .top], dx: -160, dy: 0, within: screen, keeping: 16.0 / 9.0)
        XCTAssertEqual(topLeft.x + topLeft.width, 420, accuracy: 0.0001)
        XCTAssertEqual(topLeft.y + topLeft.height, 280, accuracy: 0.0001)
        XCTAssertEqual(topLeft.width / topLeft.height, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testSideHandleGrowsAboutTheMiddle() {
        let rect = CaptureRect(x: 400, y: 400, width: 200, height: 200)
        let out = rect.resized(.right, dx: 100, dy: 0, within: screen, keeping: 1)
        assertClose(out, CaptureRect(x: 400, y: 350, width: 300, height: 300))
    }

    func testShapeNeverLeavesTheScreen() {
        let rect = CaptureRect(x: 0, y: 0, width: 900, height: 900)
        let out = rect.resized([.right, .bottom], dx: 2000, dy: 2000, within: screen, keeping: 1)
        assertClose(out, CaptureRect(x: 0, y: 0, width: 1000, height: 1000))
    }
}
