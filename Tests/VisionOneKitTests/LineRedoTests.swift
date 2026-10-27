import XCTest
@testable import VisionOneKit

final class LineRedoTests: XCTestCase {
    /// `quiet` seconds of room noise, `talk` of speech at `level`, then quiet again.
    private func envelope(quiet: Double, talk: Double, level: Float, tail: Double = 0.5) -> LoudnessEnvelope {
        let hop = 0.01
        let levels = Array(repeating: Float(-70), count: Int(quiet / hop))
            + Array(repeating: level, count: Int(talk / hop))
            + Array(repeating: Float(-70), count: Int(tail / hop))
        return LoudnessEnvelope(hop: hop, levels: levels)
    }

    func testTrimsMatchesLevelAndFits() throws {
        let slot = TimeSpan(start: 10, end: 14)
        // The original line at -20 dB, from 10 s to 14 s.
        let original = LoudnessEnvelope(hop: 0.01, levels:
            Array(repeating: Float(-70), count: 1000) + Array(repeating: Float(-20), count: 400)
            + Array(repeating: Float(-70), count: 200))
        let recording = envelope(quiet: 0.7, talk: 4.2, level: -26)
        let redo = try LineRedo.plan(slot: slot, text: "Line.", file: "redos/a.caf",
                                     recording: recording, original: original).get()
        XCTAssertEqual(redo.clipStart, 0.62, accuracy: 0.011)
        XCTAssertEqual(redo.clipEnd, 4.98, accuracy: 0.011)
        XCTAssertEqual(redo.gainDB, 6, accuracy: 0.01)
        XCTAssertEqual(redo.rate, 4.36 / 4, accuracy: 0.01)
        XCTAssertEqual(redo.state, .proposed)
    }

    func testTooLongOrSilent() {
        let slot = TimeSpan(start: 0, end: 2)
        if case .success = LineRedo.plan(slot: slot, text: "", file: "", recording: envelope(quiet: 0.2, talk: 3.5, level: -20),
                                         original: nil) {
            XCTFail("a line nearly twice as long shouldn't fit")
        }
        let silent = LoudnessEnvelope(hop: 0.01, levels: Array(repeating: -70, count: 300))
        XCTAssertEqual(LineRedo.plan(slot: slot, text: "", file: "", recording: silent, original: nil),
                       .failure(.nothingHeard))
    }

    func testANewRedoReplacesTheOldOne() {
        var list = RedoList()
        list.add(LineRedo(slot: TimeSpan(start: 1, end: 3), text: "a", file: "1", clip: TimeSpan(start: 0, end: 2), gainDB: 0))
        let second = LineRedo(slot: TimeSpan(start: 1, end: 3), text: "a", file: "2", clip: TimeSpan(start: 0, end: 2), gainDB: 0)
        list.add(second)
        XCTAssertEqual(list.redos, [second])
        list.setState(.rejected, for: second.id)
        XCTAssertTrue(list.playing.isEmpty)
    }
}

final class OutputRangeTests: XCTestCase {
    func testWholeSpanKeptOrNot() {
        let timeline = ExportTimeline(keep: [0..<5, 8..<20], sourceDuration: 20, frameRate: 0)
        XCTAssertEqual(timeline.outputRange(forSource: TimeSpan(start: 10, end: 12)), 7..<9)
        XCTAssertNil(timeline.outputRange(forSource: TimeSpan(start: 4, end: 9)))
        XCTAssertNil(timeline.outputRange(forSource: TimeSpan(start: 6, end: 7)))
    }
}
