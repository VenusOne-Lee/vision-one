import XCTest
@testable import VisionOneKit

/// Builds words from (text, start, end), with ids 0, 1, 2...
private func words(_ list: [(String, Double, Double)]) -> [TranscriptWord] {
    list.enumerated().map { TranscriptWord(id: $0.offset, text: $0.element.0, start: $0.element.1, end: $0.element.2) }
}

private func assertCut(_ cut: CutProposal?, _ start: Double, _ end: Double, _ reason: CutProposal.Reason,
                       _ ids: [Int] = [], file: StaticString = #filePath, line: UInt = #line) {
    guard let cut else { return XCTFail("no cut", file: file, line: line) }
    XCTAssertEqual(cut.start, start, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(cut.end, end, accuracy: 0.001, file: file, line: line)
    XCTAssertEqual(cut.reason, reason, file: file, line: line)
    XCTAssertEqual(cut.wordIDs, ids, file: file, line: line)
}

final class FillerLexiconTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(FillerLexicon.normalize("Um,"), "um")
        XCTAssertEqual(FillerLexicon.normalize("Nè?"), "ne")
        XCTAssertEqual(FillerLexicon.normalize("I-"), "i")
        XCTAssertEqual(FillerLexicon.normalize("don't"), "don't")
    }

    func testHesitationsInAnySpelling() {
        for word in ["um", "ummm", "uhm", "uh", "uhhh", "er", "errr", "erm", "ah", "hmm", "hmmmm", "mm"] {
            XCTAssertTrue(FillerLexicon.isHesitation(word), word)
        }
        for word in ["us", "am", "hum", "her", "", "a"] {
            XCTAssertFalse(FillerLexicon.isHesitation(word), word)
        }
    }

    func testReasonsMatchEditList() {
        XCTAssertEqual(CutProposal.Reason.filler.rawValue, "filler")
        XCTAssertEqual(CutProposal.Reason.repeated.rawValue, "repeat")
        XCTAssertEqual(CutProposal.Reason.pause.rawValue, "pause")
        XCTAssertEqual(CutProposal.Reason.deadAir.rawValue, "deadAir")
        XCTAssertEqual(CutProposal.Reason.repeated.rawValue, Cut.Reason.repeat)
    }
}

final class FillerDetectionTests: XCTestCase {
    let detector = CleanupDetector()

    func testHesitationCutClosesTheGapAfter() {
        let w = words([("I", 0, 0.2), ("was,", 0.25, 0.5), ("ummm,", 0.7, 1.0), ("going", 1.2, 1.5)])
        let cuts = detector.fillers(in: w)
        XCTAssertEqual(cuts.count, 1)
        assertCut(cuts.first, 0.7, 1.15, .filler, [2])
    }

    func testLikeInsideASentenceStays() {
        let w = words([("it's", 0, 0.2), ("like", 0.22, 0.4), ("really", 0.42, 0.6), ("good.", 0.62, 0.9)])
        XCTAssertTrue(detector.fillers(in: w).isEmpty)
    }

    func testStandaloneSoAtTheStart() {
        let w = words([("So,", 0, 0.2), ("today", 0.4, 0.7), ("we", 0.72, 0.8)])
        let cuts = detector.fillers(in: w)
        XCTAssertEqual(cuts.count, 1)
        assertCut(cuts.first, 0, 0.35, .filler, [0])
    }

    func testYouKnowAsOnePhrase() {
        let w = words([("it", 0, 0.2), ("works,", 0.25, 0.5), ("you", 0.7, 0.8), ("know,", 0.82, 1.0), ("fast.", 1.2, 1.5)])
        let cuts = detector.fillers(in: w)
        XCTAssertEqual(cuts.count, 1)
        assertCut(cuts.first, 0.7, 1.15, .filler, [2, 3])
    }

    func testSouthAfricanFillers() {
        let w = words([("Ja,", 0, 0.2), ("so", 0.25, 0.35), ("this", 0.4, 0.6), ("is,", 0.62, 0.8),
                       ("yohhh,", 0.9, 1.2), ("quick.", 1.3, 1.6)])
        let cuts = detector.fillers(in: w)
        XCTAssertEqual(cuts.map(\.wordIDs), [[0], [4]])
    }

    func testHeyOnlyAsATag() {
        let tag = words([("It's", 0, 0.2), ("lekker,", 0.25, 0.6), ("hey.", 0.65, 0.8), ("Next", 1.5, 1.8)])
        let tagCuts = detector.fillers(in: tag)
        XCTAssertEqual(tagCuts.count, 1)
        assertCut(tagCuts.first, 0.65, 1.45, .filler, [2])

        let greeting = words([("Hey,", 0, 0.2), ("everyone.", 0.3, 0.7)])
        XCTAssertTrue(detector.fillers(in: greeting).isEmpty)
    }

    func testWordsThatCarryMeaningStay() {
        let w = words([("Shame,", 0, 0.3), ("I'll", 0.5, 0.7), ("do", 0.72, 0.8), ("it", 0.82, 0.9),
                       ("now", 0.92, 1.1), ("now.", 1.12, 1.3)])
        XCTAssertTrue(detector.fillers(in: w).isEmpty)
        XCTAssertTrue(detector.repeats(in: w).isEmpty, "now now is a time, not a stutter")
    }

    func testMaybeFillersCanBeTurnedOff() {
        var settings = CleanupSettings()
        settings.maybeFillers = false
        let w = words([("So,", 0, 0.2), ("um,", 0.3, 0.5), ("today", 0.7, 1.0)])
        let cuts = CleanupDetector(settings: settings).fillers(in: w)
        XCTAssertEqual(cuts.map(\.wordIDs), [[1]])
    }
}

final class RepeatDetectionTests: XCTestCase {
    let detector = CleanupDetector()

    func testStutterKeepsTheLastWord() {
        let w = words([("I", 0, 0.1), ("I", 0.2, 0.3), ("I", 0.4, 0.5), ("think", 0.6, 0.9)])
        let cuts = detector.repeats(in: w)
        XCTAssertEqual(cuts.count, 1)
        assertCut(cuts.first, 0, 0.35, .repeated, [0, 1])
    }

    func testDeliberateRepeatsStay() {
        let w = words([("I", 0, 0.1), ("know", 0.15, 0.3), ("that", 0.35, 0.5), ("that", 0.55, 0.7),
                       ("works.", 0.75, 1.0), ("Done.", 1.2, 1.4), ("Done", 1.5, 1.7)])
        XCTAssertTrue(detector.repeats(in: w).isEmpty)
    }
}

final class PauseDetectionTests: XCTestCase {
    let detector = CleanupDetector()

    func testShortensPausesAndTrimsDeadAir() {
        let w = words([("Hello", 0.5, 1.0), ("world", 3.0, 3.4), ("again", 4.2, 4.5)])
        let cuts = detector.pauses(in: w, duration: 6)
        XCTAssertEqual(cuts.count, 3)
        assertCut(cuts[0], 0, 0.25, .deadAir)
        assertCut(cuts[1], 1.2, 2.8, .pause)
        assertCut(cuts[2], 4.75, 6, .deadAir)
    }

    func testLoudnessKeepsUntranscribedSpeech() {
        // Quiet only from 0.5 s to 2.0 s; someone talks from 2.0 s on but
        // the transcript missed it.
        let levels = (0..<350).map { i -> Float in (50..<200).contains(i) ? -70 : -20 }
        let loudness = LoudnessEnvelope(hop: 0.01, levels: levels)
        let w = words([("a", 0, 0.5), ("b", 3.0, 3.5)])

        let cuts = detector.pauses(in: w, loudness: loudness)
        XCTAssertEqual(cuts.count, 1)
        assertCut(cuts.first, 0.7, 1.8, .pause)

        let allLoud = LoudnessEnvelope(hop: 0.01, levels: Array(repeating: -20, count: 350))
        XCTAssertTrue(detector.pauses(in: w, loudness: allLoud).isEmpty)
    }

    func testReadsATranscript() {
        let transcript = Transcript(language: "en", engine: "test", duration: 4, segments: [
            TranscriptSegment(words: words([("Hello.", 0.1, 0.5), ("Um,", 2.0, 2.2), ("hi.", 2.3, 2.6)])),
        ])
        let cuts = CleanupDetector().proposals(for: transcript)
        XCTAssertEqual(cuts.map(\.reason), [.pause, .filler, .deadAir])
    }

    func testNoWordsNoCuts() {
        XCTAssertTrue(detector.proposals(for: [], duration: 10).isEmpty)
    }
}

final class LoudnessTests: XCTestCase {
    func testMeasure() {
        let rate = 48_000.0
        let tone = (0..<48_000).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
        let envelope = LoudnessEnvelope.measure(samples: tone + Array(repeating: 0, count: 4_800), sampleRate: rate)
        XCTAssertEqual(envelope.levels.count, 110)
        XCTAssertEqual(envelope.levels[10], -3.01, accuracy: 0.1)
        XCTAssertEqual(envelope.levels.last, LoudnessEnvelope.floorDB)
    }

    func testSilentSpansBridgeBlips() {
        var levels = Array(repeating: Float(-70), count: 200)
        levels[100] = -10 // a click
        let spans = LoudnessEnvelope(hop: 0.01, levels: levels).silentSpans(threshold: -50, minDuration: 1.5)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.duration ?? 0, 2.0, accuracy: 0.001)
    }

    func testAdaptiveThresholdStaysInRange() {
        XCTAssertEqual(LoudnessEnvelope(hop: 0.01, levels: Array(repeating: -100, count: 10)).adaptiveThreshold, -60)
        XCTAssertEqual(LoudnessEnvelope(hop: 0.01, levels: Array(repeating: -10, count: 10)).adaptiveThreshold, -35)
    }
}

final class CleanupProposalsTests: XCTestCase {
    func testMergesTouchingCutsAndPrefersFiller() {
        let detector = CleanupDetector()
        let merged = detector.merge([
            CutProposal(start: 1.5, end: 3, reason: .filler, wordIDs: [4]),
            CutProposal(start: 1, end: 2, reason: .pause),
            CutProposal(start: 5, end: 6, reason: .pause),
        ])
        XCTAssertEqual(merged.count, 2)
        assertCut(merged[0], 1, 3, .filler, [4])
        assertCut(merged[1], 5, 6, .pause)
    }

    func testProposesIntoTheEditListWithoutRepeatingRejections() {
        var list = EditList(sourceDuration: 10)
        list.add(Cut(span: TimeSpan(start: 1, end: 2), reason: Cut.Reason.pause, state: .rejected))
        let added = list.propose([
            CutProposal(start: 1.2, end: 1.8, reason: .pause),
            CutProposal(start: 4, end: 4.5, reason: .filler, wordIDs: [7]),
        ])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.reason, Cut.Reason.filler)
        XCTAssertEqual(added.first?.state, .proposed)
        XCTAssertEqual(list.removedSpans, [], "proposals don't change the video until accepted")
    }

    func testWholeTake() {
        let w = words([
            ("Ja,", 0.8, 1.0), ("um,", 1.3, 1.6), ("so", 1.8, 1.9), ("this", 1.95, 2.1), ("is", 2.15, 2.3),
            ("the", 2.35, 2.45), ("the", 2.5, 2.6), ("recorder.", 2.65, 3.2), ("Let's", 5.0, 5.3), ("go.", 5.35, 5.6),
        ])
        let cuts = CleanupDetector().proposals(for: w, duration: 7)
        // Dead air at the start, "Ja," + "um," (they touch), "the",
        // the pause after "recorder.", dead air at the end.
        XCTAssertEqual(cuts.map(\.reason), [.deadAir, .filler, .repeated, .pause, .deadAir])
        assertCut(cuts[0], 0, 0.55, .deadAir)
        assertCut(cuts[1], 0.8, 1.75, .filler, [0, 1])
        assertCut(cuts[2], 2.35, 2.45, .repeated, [5])
        assertCut(cuts[3], 3.4, 4.8, .pause)
        assertCut(cuts[4], 5.85, 7, .deadAir)
    }
}
