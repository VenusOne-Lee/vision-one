import XCTest
@testable import VisionOneKit

final class CameraBubbleTests: XCTestCase {
    private let screen = CaptureRect(x: 0, y: 0, width: 1440, height: 900)

    func testStandardSitsBottomLeftAtMediumSize() {
        let frame = BubblePlacement.standard(on: screen).frame(on: screen)
        XCTAssertEqual(frame.width, 200)
        XCTAssertEqual(frame.height, 200)
        XCTAssertEqual(frame.x, 32, accuracy: 1e-9)
        XCTAssertEqual(frame.y, 32, accuracy: 1e-9)
    }

    func testFrameRoundTripsThroughPlacement() {
        let dragged = CaptureRect(x: 600, y: 300, width: 180, height: 180)
        let placement = BubblePlacement(frame: dragged, on: screen)
        assertSame(placement.frame(on: screen), dragged)
    }

    func testDraggedOffScreenIsPulledBackInside() {
        let dragged = CaptureRect(x: 1400, y: -80, width: 200, height: 200)
        let frame = BubblePlacement(frame: dragged, on: screen).frame(on: screen)
        XCTAssertEqual(frame.x, 1440 - 16 - 200)
        XCTAssertEqual(frame.y, 16)
    }

    func testSizeIsKeptBetweenMinimumAndHalfTheScreen() {
        XCTAssertEqual(BubblePlacement.clampedDiameter(20, on: screen), 96)
        XCTAssertEqual(BubblePlacement.clampedDiameter(2000, on: screen), 450)
        XCTAssertEqual(BubblePlacement.clampedDiameter(250, on: screen), 250)
    }

    func testResizeKeepsTheCentre() {
        let placement = BubblePlacement(frame: CaptureRect(x: 600, y: 300, width: 200, height: 200), on: screen)
        let bigger = placement.resized(to: 300, on: screen).frame(on: screen)
        assertSame(bigger, CaptureRect(x: 550, y: 250, width: 300, height: 300))
    }

    func testSameShareOnABiggerScreen() {
        let placement = BubblePlacement(frame: CaptureRect(x: 620, y: 350, width: 200, height: 200), on: screen)
        let big = CaptureRect(x: 0, y: 0, width: 2880, height: 1800)
        let frame = placement.frame(on: big)
        XCTAssertEqual(frame.x + frame.width / 2, 1440, accuracy: 1e-9)
        XCTAssertEqual(frame.y + frame.height / 2, 900, accuracy: 1e-9)
        XCTAssertEqual(frame.width, 200)
    }

    func testScreenOnASecondDisplayKeepsItsOrigin() {
        let second = CaptureRect(x: 1440, y: 0, width: 1920, height: 1080)
        let dragged = CaptureRect(x: 2000, y: 400, width: 200, height: 200)
        assertSame(BubblePlacement(frame: dragged, on: second).frame(on: second), dragged)
    }

    func testPlacementIsRelativeToWhatWasRecorded() throws {
        let recorded = CaptureRect(x: 100, y: 50, width: 800, height: 600)
        let bubble = CaptureRect(x: 500, y: 350, width: 200, height: 200)
        let placement = try XCTUnwrap(CameraTrack.Placement(t: 2, bubble: bubble, recorded: recorded))
        XCTAssertEqual(placement.x, 0.5)
        XCTAssertEqual(placement.y, 0.5)
        XCTAssertEqual(placement.size, 0.25)
    }

    func testRecordSkipsStillPlacementsAndMergesTheSameInstant() {
        var track = CameraTrack(cameraName: "FaceTime HD Camera", startOffset: 0.12)
        track.record(.init(t: 0, x: 0.1, y: 0.8, size: 0.2))
        track.record(.init(t: 1, x: 0.1, y: 0.8, size: 0.2))
        XCTAssertEqual(track.placements.count, 1)
        track.record(.init(t: 2, x: 0.3, y: 0.8, size: 0.2))
        track.record(.init(t: 2.01, x: 0.35, y: 0.8, size: 0.2))
        XCTAssertEqual(track.placements.count, 2)
        XCTAssertEqual(track.placements.last?.x, 0.35)
    }

    func testPlacementAtTime() {
        var track = CameraTrack(cameraName: "Cam", startOffset: 0)
        track.record(.init(t: 0, x: 0.1, y: 0.1, size: 0.2))
        track.record(.init(t: 5, x: 0.6, y: 0.1, size: 0.2))
        XCTAssertEqual(track.placement(at: 3)?.x, 0.1)
        XCTAssertEqual(track.placement(at: 5)?.x, 0.6)
        XCTAssertEqual(track.placement(at: 60)?.x, 0.6)
    }

    func testCameraTrackRoundTrips() throws {
        var track = CameraTrack(cameraName: "Lee's iPhone Camera", startOffset: -0.04)
        track.record(.init(t: 0, x: 0.02, y: 0.7, size: 0.14))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try track.write(to: url)
        XCTAssertEqual(try CameraTrack.read(from: url), track)
    }

    private func assertSame(_ a: CaptureRect, _ b: CaptureRect, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.x, b.x), (a.y, b.y), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 1e-9, file: file, line: line)
        }
    }

    func testOutputRectFlipsToBottomLeftAndStaysInside() {
        let frame = CaptureRect(x: 0, y: 0, width: 1920, height: 1080)
        let bottomLeft = CameraTrack.Placement(t: 0, x: 0.02, y: 0.7, size: 0.15)
        let rect = CameraTrack.outputRect(for: bottomLeft, in: frame)
        assertSame(rect, CaptureRect(x: 38.4, y: 1080 - 756 - 288, width: 288, height: 288))

        let offEdge = CameraTrack.Placement(t: 0, x: 0.95, y: 0.95, size: 0.2)
        let kept = CameraTrack.outputRect(for: offEdge, in: frame)
        assertSame(kept, CaptureRect(x: 1920 - 384, y: 0, width: 384, height: 384))
    }

    func testOutputRectUsesTheLetterboxedFrame() {
        let frame = CaptureRect(x: 240, y: 0, width: 1440, height: 1080)
        let rect = CameraTrack.outputRect(for: .init(t: 0, x: 0, y: 0, size: 0.1), in: frame)
        assertSame(rect, CaptureRect(x: 240, y: 1080 - 144, width: 144, height: 144))
    }

    func testPlacementFollowsTheRecordingThroughCuts() {
        var track = CameraTrack(cameraName: "Cam", startOffset: -0.1)
        track.record(.init(t: 0, x: 0.1, y: 0.1, size: 0.2))
        track.record(.init(t: 10, x: 0.7, y: 0.1, size: 0.2))
        // Keep 0-5 s and 12-20 s: output 6 s is source 13 s.
        let timeline = ExportTimeline(keep: [0..<5, 12..<20], sourceDuration: 20, frameRate: 30)
        XCTAssertEqual(track.placement(atOutput: 2, timeline: timeline)?.x, 0.1)
        XCTAssertEqual(track.placement(atOutput: 6, timeline: timeline)?.x, 0.7)
        XCTAssertEqual(track.cameraTime(forScreen: 13), 13.1, accuracy: 1e-9)
    }
}
