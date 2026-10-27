import XCTest
@testable import VisionOneKit

private func words(_ list: [(String, Double, Double)]) -> [TranscriptWord] {
    list.enumerated().map { TranscriptWord(id: $0.offset, text: $0.element.0, start: $0.element.1, end: $0.element.2) }
}

/// Levels every 10 ms: loud (-20 dB) inside `loud`, quiet (-70 dB) elsewhere.
private func levels(seconds: Double, loud: [ClosedRange<Double>]) -> LoudnessEnvelope {
    let count = Int((seconds * 100).rounded())
    let values = (0..<count).map { i -> Float in
        let t = Double(i) / 100
        return loud.contains { $0.contains(t) } ? -20 : -70
    }
    return LoudnessEnvelope(hop: 0.01, levels: values)
}

final class DeadAirLoudnessTests: XCTestCase {
    /// Lee's 37 s take: the transcript only caught two words, at 13 s and
    /// 26 s, but he talked from 3 s to 31 s. Silence at the edges must
    /// stop where the mic gets loud, not at the first word it heard.
    func testEdgesStopWhereTheMicGetsLoud() {
        let w = words([("so", 13.0, 13.3), ("uh", 26.0, 26.2)])
        let loudness = levels(seconds: 37, loud: [3.0...31.0])
        let cuts = CleanupDetector().pauses(in: w, duration: 37, loudness: loudness)
        let edges = cuts.filter { $0.reason == .deadAir }
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(edges[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(edges[0].end, 2.75, accuracy: 0.02)
        XCTAssertEqual(edges[1].start, 31.26, accuracy: 0.02)
        XCTAssertEqual(edges[1].end, 37, accuracy: 0.001)
        // The 12.7 s between the words is loud, so it isn't a pause.
        XCTAssertFalse(cuts.contains { $0.reason == .pause })
    }

    func testLoudFromTheFirstFrameMeansNoLeadingCut() {
        let w = words([("hi", 2.0, 2.4)])
        let loudness = levels(seconds: 5, loud: [0...2.5])
        let cuts = CleanupDetector().pauses(in: w, duration: 5, loudness: loudness)
        XCTAssertEqual(cuts.map(\.reason), [.deadAir])
        XCTAssertEqual(cuts[0].start, 2.76, accuracy: 0.02)
    }

    func testWithoutLevelsWordsDecide() {
        let w = words([("hi", 2.0, 2.4)])
        let cuts = CleanupDetector().pauses(in: w, duration: 5)
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts[0].end, 1.75, accuracy: 0.001)
        XCTAssertEqual(cuts[1].start, 2.65, accuracy: 0.001)
    }
}

final class SilenceCutTests: XCTestCase {
    func testUnderstandsSilenceAsks() {
        for ask in ["cut the video where you don't hear someone talking", "Remove the silence",
                    "cut the pauses", "take out dead air", "cut where nobody talks", "cut where you don’t hear me"] {
            XCTAssertTrue(SilenceCut.isSilenceAsk(ask), ask)
        }
        for ask in ["make it 60s", "Make a 45 second TikTok, hook first", "drop the intro"] {
            XCTAssertFalse(SilenceCut.isSilenceAsk(ask), ask)
        }
    }

    func testFindsQuietFromTheMic() {
        // Talking 2-5 s and 9-12 s in a 15 s take; one word caught.
        let loudness = levels(seconds: 15, loud: [2...5, 9...12])
        let cuts = SilenceCut.proposals(words: words([("hello", 2.1, 2.5)]), duration: 15, loudness: loudness)
        XCTAssertEqual(cuts.map(\.reason), [.deadAir, .pause, .deadAir])
        XCTAssertEqual(cuts[0].end, 1.75, accuracy: 0.02)
        XCTAssertEqual(cuts[1].start, 5.21, accuracy: 0.02)
        XCTAssertEqual(cuts[1].end, 8.8, accuracy: 0.02)
        XCTAssertEqual(cuts[2].start, 12.26, accuracy: 0.02)
        XCTAssertEqual(cuts[2].end, 15, accuracy: 0.001)
    }

    func testAQuietWordStays() {
        // The mic barely caught "yes" at 6 s, but the transcript has it.
        let loudness = levels(seconds: 10, loud: [0...2, 8...10])
        let cuts = SilenceCut.proposals(words: words([("a", 1, 1.5), ("yes", 6.0, 6.3), ("b", 8.2, 8.5)]),
                                        duration: 10, loudness: loudness)
        XCTAssertFalse(cuts.contains { $0.start < 6.3 && 6.0 < $0.end })
        XCTAssertEqual(cuts.count, 2)
    }

    func testSoundStoppingEarlyCutsToTheEndOfTheVideo() {
        let loudness = levels(seconds: 5, loud: [0...4.99])
        let cuts = SilenceCut.proposals(words: [], duration: 12, loudness: loudness)
        XCTAssertEqual(cuts.map(\.reason), [.deadAir])
        XCTAssertEqual(cuts[0].end, 12, accuracy: 0.001)
    }

    func testNeverCutsAWhollySilentTake() {
        let loudness = levels(seconds: 10, loud: [])
        XCTAssertTrue(SilenceCut.proposals(words: [], duration: 10, loudness: loudness).isEmpty)
    }

    func testGapsBetweenWordsWithoutLevels() {
        let cuts = SilenceCut.proposals(words: words([("a", 1, 1.5), ("b", 4, 4.5)]), duration: 6, loudness: nil)
        XCTAssertEqual(cuts.map(\.reason), [.pause, .deadAir])
        XCTAssertEqual(cuts[0].start, 1.7, accuracy: 0.001)
        XCTAssertEqual(cuts[0].end, 3.8, accuracy: 0.001)
    }

    func testApplyReplacesStaleSuggestionsAndAccepts() {
        var edits = EditList(sourceDuration: 37)
        // Old dead-air suggestion that swallowed speech; a rejected filler.
        edits.add(Cut(span: TimeSpan(start: 0, end: 12.8), reason: Cut.Reason.deadAir, state: .proposed))
        edits.add(Cut(span: TimeSpan(start: 20, end: 20.3), reason: Cut.Reason.filler, state: .rejected))
        let fresh = [CutProposal(start: 0, end: 2.75, reason: .deadAir),
                     CutProposal(start: 31.26, end: 37, reason: .deadAir)]
        let result = SilenceCut.apply(fresh, to: edits)
        XCTAssertEqual(result.stretches, 2)
        XCTAssertEqual(result.removedSeconds, 2.75 + 5.74, accuracy: 0.001)
        XCTAssertFalse(result.edits.cuts.contains { $0.span.end == 12.8 }, "the stale suggestion is gone")
        XCTAssertTrue(result.edits.cuts.contains { $0.reason == Cut.Reason.filler && $0.state == .rejected })
        XCTAssertEqual(result.edits.removedSpans.count, 2)
    }

    func testApplyTwiceAddsNothing() {
        let fresh = [CutProposal(start: 3, end: 5, reason: .pause)]
        let once = SilenceCut.apply(fresh, to: EditList(sourceDuration: 10))
        let twice = SilenceCut.apply(fresh, to: once.edits)
        XCTAssertEqual(twice.stretches, 0)
        XCTAssertEqual(twice.removedSeconds, 0, accuracy: 1e-9)
    }

    func testRefreshKeepsDecisions() {
        var edits = EditList(sourceDuration: 20)
        edits.add(Cut(span: TimeSpan(start: 0, end: 9), reason: Cut.Reason.deadAir, state: .proposed))
        edits.add(Cut(span: TimeSpan(start: 12, end: 14), reason: Cut.Reason.pause, state: .rejected))
        let next = SilenceCut.refreshSuggestions(edits, with: [
            CutProposal(start: 0, end: 1.5, reason: .deadAir),
            CutProposal(start: 12.5, end: 13.5, reason: .pause),
        ])
        XCTAssertEqual(next.cuts.count, 2)
        XCTAssertTrue(next.cuts.contains { $0.end == 1.5 && $0.state == .proposed })
        XCTAssertTrue(next.cuts.contains { $0.start == 12 && $0.state == .rejected }, "a turned-down pause isn't suggested again")
    }
}

final class LevelsFileTests: XCTestCase {
    func testRoundTripsToWholeDecibels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let envelope = LoudnessEnvelope(hop: 0.01, levels: [-100, -62.4, -20.6, -0.2, 3])
        try envelope.write(to: url)
        let read = try LoudnessEnvelope.read(from: url)
        XCTAssertEqual(read.hop, 0.01)
        XCTAssertEqual(read.levels, [-100, -62, -21, 0, 0])
    }

    func testPeakAndAmplitude() {
        let envelope = LoudnessEnvelope(hop: 0.1, levels: [-70, -30, -10, -50])
        XCTAssertEqual(envelope.peak(from: 0, to: 0.15), -30)
        XCTAssertEqual(envelope.peak(from: 0.2, to: 5), -10)
        XCTAssertEqual(envelope.peak(from: 9, to: 10), LoudnessEnvelope.floorDB)
        XCTAssertEqual(LoudnessEnvelope.amplitude(db: -60), 0)
        XCTAssertEqual(LoudnessEnvelope.amplitude(db: -30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(LoudnessEnvelope.amplitude(db: 0), 1)
    }
}
