import XCTest
@testable import VisionOneKit

final class TranscriptTests: XCTestCase {
    private func sample() -> Transcript {
        Transcript(
            language: "en",
            engine: "test",
            duration: 6,
            createdAt: Date(timeIntervalSince1970: 1_793_098_392),
            segments: [
                TranscriptSegment(words: [
                    TranscriptWord(id: 0, text: "Um,", start: 0.5, end: 0.8, confidence: 0.6),
                    TranscriptWord(id: 1, text: "hello", start: 0.9, end: 1.2),
                    TranscriptWord(id: 2, text: "there.", start: 1.2, end: 1.6),
                ]),
                TranscriptSegment(words: [
                    TranscriptWord(id: 3, text: "Ship", start: 3.0, end: 3.3),
                    TranscriptWord(id: 4, text: "it.", start: 3.3, end: 3.7),
                ]),
            ]
        )
    }

    func testFlatWordsAndText() {
        let t = sample()
        XCTAssertEqual(t.words.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(t.text, "Um, hello there.\nShip it.")
        XCTAssertEqual(t.segments[1].start, 3.0)
        XCTAssertEqual(t.segments[1].end, 3.7)
    }

    func testNormalized() {
        XCTAssertEqual(sample().words[0].normalized, "um")
        XCTAssertEqual(TranscriptWord(id: 9, text: "it's.", start: 0, end: 1).normalized, "it's")
    }

    func testLookups() {
        let t = sample()
        XCTAssertEqual(t.word(at: 1.0)?.id, 1)
        XCTAssertEqual(t.word(at: 1.2)?.id, 2, "end is exclusive")
        XCTAssertNil(t.word(at: 2.0))
        XCTAssertEqual(t.word(id: 3)?.text, "Ship")
        XCTAssertEqual(t.words(from: 1.5, to: 3.1).map(\.id), [2, 3])
    }

    func testGapsIncludeEdges() {
        let gaps = sample().gaps(minimum: 0.5)
        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0], TranscriptGap(afterWordID: nil, beforeWordID: 0, start: 0, end: 0.5))
        XCTAssertEqual(gaps[1], TranscriptGap(afterWordID: 2, beforeWordID: 3, start: 1.6, end: 3.0))
        XCTAssertEqual(gaps[2], TranscriptGap(afterWordID: 4, beforeWordID: nil, start: 3.7, end: 6))
        XCTAssertEqual(sample().gaps(minimum: 2).count, 1)
    }

    func testValidateCatchesBadTranscripts() {
        var t = sample()
        t.segments[1].words[0] = TranscriptWord(id: 1, text: "x", start: 3.0, end: 3.3)
        XCTAssertThrowsError(try t.validate()) { XCTAssertEqual($0 as? TranscriptError, .duplicateID(1)) }

        t = sample()
        t.segments[0].words[1].end = 0.9
        XCTAssertThrowsError(try t.validate()) { XCTAssertEqual($0 as? TranscriptError, .badTiming(1)) }

        t = sample()
        t.segments[1].words[0].start = 0.1
        XCTAssertThrowsError(try t.validate()) { XCTAssertEqual($0 as? TranscriptError, .outOfOrder(3)) }

        XCTAssertNoThrow(try sample().validate())
    }

    func testRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try sample().write(to: url)
        XCTAssertEqual(try Transcript.read(from: url), sample())
    }

    func testRefusesNewerVersion() throws {
        var t = sample()
        t.version = Transcript.currentVersion + 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try t.write(to: url)
        XCTAssertThrowsError(try Transcript.read(from: url)) {
            XCTAssertEqual($0 as? TranscriptError, .newerVersion(Transcript.currentVersion + 1))
        }
    }

    func testDecodesDocumentedExample() throws {
        let json = """
        {
          "version": 1, "language": "en", "engine": "parakeet-tdt-0.6b-v2",
          "audioTrack": "mic", "duration": 4.2, "createdAt": "2026-10-27T10:55:01Z",
          "segments": [{ "words": [
            { "id": 0, "text": "So,", "start": 0.42, "end": 0.61, "confidence": 0.93 },
            { "id": 1, "text": "today", "start": 0.66, "end": 0.98 }
          ]}]
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let t = try Transcript.read(from: url)
        XCTAssertEqual(t.words.count, 2)
        XCTAssertNil(t.words[1].confidence)
        XCTAssertNil(t.words[0].speaker)
    }
}
