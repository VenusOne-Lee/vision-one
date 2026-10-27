import XCTest
@testable import VisionOneKit

final class ThumbnailPickerTests: XCTestCase {
    func testSampleTimesSkipTheEdgesAndStayOutOfCuts() {
        var edits = EditList(sourceDuration: 100)
        edits.add(Cut(span: TimeSpan(start: 40, end: 60)))
        var picker = ThumbnailPicker()
        picker.sampleCount = 8
        let times = picker.sampleTimes(edits: edits)
        XCTAssertEqual(times.count, 8)
        for t in times {
            XCTAssertFalse(edits.isRemoved(t))
            XCTAssertGreaterThan(t, 3.9)
            XCTAssertLessThan(t, 96.1)
            XCTAssertGreaterThanOrEqual(picker.distanceFromCut(t, edits: edits), 0.5 - 1e-9)
        }
    }

    func testRankPrefersSharpFacesAndSpreadsPicks() {
        var picker = ThumbnailPicker()
        picker.offerCount = 2
        let picks = picker.rank([
            .init(time: 10, sharpness: 0.9, faceQuality: 0.9),
            .init(time: 11, sharpness: 0.9, faceQuality: 0.85), // too close to 10
            .init(time: 30, sharpness: 0.2),
            .init(time: 50, sharpness: 0.8, faceQuality: 0.6),
        ])
        XCTAssertEqual(picks.map(\.time), [10, 50])
    }

    func testRushingCursorScoresLower() {
        let still = ThumbnailPicker.Metrics(time: 1, sharpness: 0.8, cursorSpeed: 0)
        let rushing = ThumbnailPicker.Metrics(time: 1, sharpness: 0.8, cursorSpeed: 1)
        XCTAssertGreaterThan(still.score, rushing.score)
    }

    func testCursorSpeed() {
        var log = EventLog(displayWidth: 1000, displayHeight: 500)
        log.append(InputEvent(kind: .move, t: 5.0, x: 0, y: 0))
        log.append(InputEvent(kind: .move, t: 5.2, x: 500, y: 0))
        XCTAssertEqual(ThumbnailPicker.cursorSpeed(at: 5.1, events: log, window: 0.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(ThumbnailPicker.cursorSpeed(at: 20, events: log), 0)
    }
}

final class ThumbnailDesignTests: XCTestCase {
    func testTitleSuggestionPrefersTheBestClip() {
        var clips = ClipList()
        clips.add(Clip(title: "Ship your first beta in ten minutes flat", span: TimeSpan(start: 0, end: 20)), sourceDuration: 30)
        let title = ThumbnailTitle.suggested(transcript: nil, clips: clips, edits: EditList(sourceDuration: 30))
        XCTAssertEqual(title, "Ship your first beta in ten")
    }

    func testTitleSuggestionFallsBackToTheFirstSentence() {
        let transcript = makeTranscript(["Uh, today we launch.", "More later."])
        let title = ThumbnailTitle.suggested(transcript: transcript, clips: nil,
                                             edits: EditList(sourceDuration: transcript.duration))
        XCTAssertEqual(title, "Today we launch")
    }

    func testLinesNeverSplitWords() {
        XCTAssertEqual(ThumbnailTitle.lines("Ship your first beta today", maxCharacters: 10),
                       ["Ship your", "first beta", "today"])
    }

    func testMovingTheTitleKeepsItOnTheImage() {
        var design = ThumbnailDesign(time: 3, title: "Hi", titleWidth: 0.6)
        design.moveTitle(x: 0.9, y: 2)
        XCTAssertEqual(design.titleX, 0.4, accuracy: 1e-9)
        XCTAssertEqual(design.titleY, 0.95, accuracy: 1e-9)
    }

    func testDesignRoundTrips() throws {
        let design = ThumbnailDesign(time: 12.5, title: "Launch day", sizes: [.youtube, .cover])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID())", isDirectory: true)
            .appendingPathComponent("thumbnail.json")
        try design.write(to: url)
        XCTAssertEqual(try ThumbnailDesign.read(from: url), design)
    }

    func testSizes() {
        XCTAssertEqual(ThumbnailSize.youtube.pixels.width, 1280)
        XCTAssertEqual(ThumbnailSize.youtube.fileExtension, "jpg")
        XCTAssertEqual(ThumbnailSize.cover.pixels.height, 1920)
        XCTAssertEqual(ThumbnailStyle.rgb("#E0A21B"), 0xE0A21B)
        XCTAssertNil(ThumbnailStyle.rgb("nope"))
    }
}
