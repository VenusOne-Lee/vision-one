import XCTest
@testable import VisionOneKit

final class TranscriptBuilderTests: XCTestCase {
    private func build(_ pieces: [RecognizedPiece], duration: Double = 10) -> Transcript {
        TranscriptBuilder.build(pieces: pieces, language: "en", engine: "test", duration: duration)
    }

    func testJoinsSubwordPiecesAndPunctuation() {
        let t = build([
            RecognizedPiece(text: "▁Hel", start: 0.40, end: 0.50, confidence: 0.9, startsWord: true),
            RecognizedPiece(text: "lo", start: 0.50, end: 0.70, confidence: 0.7, startsWord: false),
            RecognizedPiece(text: ",", start: 0.70, end: 0.72, confidence: 0.2, startsWord: false),
            RecognizedPiece(text: "▁world", start: 0.80, end: 1.10, startsWord: true),
            RecognizedPiece(text: "▁.", start: 1.10, end: 1.12, startsWord: true),
        ])
        XCTAssertEqual(t.words.map(\.text), ["Hello,", "world."])
        XCTAssertEqual(t.words[0].start, 0.40)
        XCTAssertEqual(t.words[0].end, 0.70, "punctuation doesn't stretch the word")
        XCTAssertEqual(t.words[0].confidence!, 0.8, accuracy: 0.0001)
        XCTAssertNil(t.words[1].confidence)
        XCTAssertEqual(t.words.map(\.id), [0, 1])
        XCTAssertNoThrow(try t.validate())
    }

    func testWholeWordsFromWhisper() {
        let t = build([
            RecognizedPiece(text: " Um,", start: 0.1, end: 0.4, startsWord: true),
            RecognizedPiece(text: " ja", start: 0.5, end: 0.7, startsWord: true),
        ])
        XCTAssertEqual(t.words.map(\.normalized), ["um", "ja"])
    }

    func testTidiesBadTimings() throws {
        let t = build([
            RecognizedPiece(text: "▁a", start: -0.5, end: 0.3, startsWord: true),
            RecognizedPiece(text: "▁b", start: 0.2, end: 0.2, startsWord: true),   // overlaps, no length
            RecognizedPiece(text: "▁c", start: 0.1, end: 0.6, startsWord: true),   // out of order
            RecognizedPiece(text: "▁d", start: 9.99, end: 12, startsWord: true),   // past the end
        ], duration: 10)
        XCTAssertNoThrow(try t.validate())
        let w = t.words
        XCTAssertEqual(w[0].start, 0)
        for (a, b) in zip(w, w.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "\(a.text) overlaps \(b.text)")
            XCTAssertGreaterThan(a.end, a.start)
        }
        XCTAssertLessThanOrEqual(w[3].end, 10)
    }

    func testSegmentsOnSentencesAndPauses() {
        let t = build([
            RecognizedPiece(text: "▁One.", start: 0.0, end: 0.3, startsWord: true),
            RecognizedPiece(text: "▁Two", start: 0.4, end: 0.6, startsWord: true),
            RecognizedPiece(text: "▁three", start: 2.0, end: 2.3, startsWord: true), // after a pause
            RecognizedPiece(text: "▁four?", start: 2.4, end: 2.6, startsWord: true),
            RecognizedPiece(text: "▁five", start: 2.7, end: 2.9, startsWord: true),
        ])
        XCTAssertEqual(t.segments.map(\.text), ["One.", "Two", "three four?", "five"])
    }

    func testSplitsLongRunOns() {
        let pieces = (0..<100).map {
            RecognizedPiece(text: "▁w", start: Double($0) * 0.1, end: Double($0) * 0.1 + 0.05, startsWord: true)
        }
        let t = build(pieces)
        XCTAssertEqual(t.segments.map(\.words.count), [40, 40, 20])
    }

    func testEmpty() {
        XCTAssertTrue(build([]).isEmpty)
        XCTAssertTrue(build([RecognizedPiece(text: "▁", start: 0, end: 1, startsWord: true)]).isEmpty)
    }
}

final class SampleTimelineTests: XCTestCase {
    func testPadsGapsAndDropsOverlaps() {
        var t = SampleTimeline(sampleRate: 10)
        t.append([1, 1, 1], at: 0.2)       // starts late: two samples of silence first
        XCTAssertEqual(t.samples, [0, 0, 1, 1, 1])
        t.append([2, 2, 2], at: 0.4)       // overlaps by one
        XCTAssertEqual(t.samples, [0, 0, 1, 1, 1, 2, 2])
        t.append([3], at: 0.9)             // mic dropped out
        XCTAssertEqual(t.samples, [0, 0, 1, 1, 1, 2, 2, 0, 0, 3])
        t.append([4, 4], at: 0.0)          // entirely in the past
        XCTAssertEqual(t.samples.count, 10)
        XCTAssertEqual(t.duration, 1.0)
    }
}

final class TranscriptionPhaseTests: XCTestCase {
    func testStatusText() {
        XCTAssertNil(TranscriptionPhase.idle.statusText)
        XCTAssertEqual(TranscriptionPhase.downloadingModel(progress: 0.426).statusText,
                       "Getting the speech model… 43%")
        XCTAssertEqual(TranscriptionPhase.downloadingModel(progress: nil).statusText,
                       "Getting the speech model…")
        XCTAssertTrue(TranscriptionPhase.transcribing(takeName: "x").isWorking)
        XCTAssertFalse(TranscriptionPhase.failed(takeName: "x", message: "m").isWorking)
    }
}
