import XCTest
@testable import VisionOneKit

/// Words said back to back, `step` seconds each, from `start`.
private func words(_ sentence: String, start: Double = 0, step: Double = 0.3) -> [CaptionWord] {
    sentence.split(separator: " ").enumerated().map { i, text in
        CaptionWord(text: String(text), start: start + Double(i) * step, end: start + Double(i + 1) * step)
    }
}

final class CaptionBuilderTests: XCTestCase {
    func testBreaksAtSentenceEnds() {
        let cues = CaptionBuilder(layout: .subtitle).cues(for: words("Hello world. This is Vision One."))
        XCTAssertEqual(cues.map(\.text), ["Hello world.", "This is Vision One."])
        XCTAssertEqual(cues[0].start, 0, accuracy: 0.0001)
        // Stretching never runs into the next cue.
        XCTAssertLessThanOrEqual(cues[0].end, cues[1].start)
    }

    func testBreaksAtPauses() {
        let first = words("So here we go")
        let second = words("and it works", start: 3)
        let cues = CaptionBuilder(layout: .subtitle).cues(for: first + second)
        XCTAssertEqual(cues.map(\.text), ["So here we go", "and it works"])
    }

    func testCutWordsDropOutAndTheRestAreRetimed() {
        let input = [
            CaptionWord(text: "Ship", start: 0, end: 0.5),
            CaptionWord(text: "um", start: 0.5, end: 1.0),
            CaptionWord(text: "it.", start: 1.0, end: 1.5),
        ]
        // The filler from 0.5 s to 1.0 s is cut.
        let outputTime: (Double) -> Double? = { t in
            if t < 0.5 { return t }
            if t < 1.0 { return nil }
            return t - 0.5
        }
        let cues = CaptionBuilder(layout: .subtitle).cues(for: input, outputTime: outputTime)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Ship it.")
        let retimed = cues[0].words
        XCTAssertEqual(retimed[0].end, 0.5, accuracy: 0.0001)
        XCTAssertEqual(retimed[1].start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(retimed[1].end, 1.0, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 1.0, accuracy: 0.0001)
    }

    func testSplitsTwoLinesBeforeAConjunction() {
        let sentence = "I built this in two weekends and it already has users who love it"
        let cues = CaptionBuilder(layout: .subtitle).cues(for: words(sentence))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "I built this in two weekends\nand it already has users who love it")
        for line in cues[0].lines {
            XCTAssertLessThanOrEqual(CaptionBuilder.length(line), 42)
        }
    }

    func testLinesNeverPassTheLimit() {
        let sentence = Array(repeating: "captions should always be easy to read on a phone", count: 6)
            .joined(separator: " ")
        let cues = CaptionBuilder(layout: .subtitle).cues(for: words(sentence, step: 0.2))
        XCTAssertGreaterThan(cues.count, 1)
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.lines.count, 2)
            for line in cue.lines {
                XCTAssertLessThanOrEqual(CaptionBuilder.length(line), 42)
            }
            XCTAssertLessThanOrEqual(cue.words.last!.end - cue.start, 7.0001)
        }
        XCTAssertEqual(cues.flatMap(\.words).count, sentence.split(separator: " ").count)
    }

    func testWordByWordShowsAFewWordsAtATime() {
        let sentence = "I built this in two weekends and it already has users who love it"
        let cues = CaptionBuilder(layout: .wordByWord).cues(for: words(sentence))
        XCTAssertEqual(cues.map(\.text), [
            "I built this in", "two weekends and it", "already has users who", "love it",
        ])
    }

    func testShortCuesStayUpLongEnoughToRead() {
        let cues = CaptionBuilder(layout: .subtitle).cues(for: [CaptionWord(text: "Hi", start: 0, end: 0.2)])
        XCTAssertEqual(cues[0].end, 5.0 / 6.0, accuracy: 0.0001)
    }

    func testCuesNeverOverlap() {
        let a = words("one two three.", step: 0.1)
        let b = words("four five six.", start: 0.35, step: 0.1)
        let cues = CaptionBuilder(layout: .subtitle).cues(for: a + b)
        XCTAssertEqual(cues.count, 2)
        XCTAssertLessThanOrEqual(cues[0].end, cues[1].start)
    }

    func testMarksKeywords() {
        let cues = CaptionBuilder(layout: .subtitle, keywordNames: ["Vercel"])
            .cues(for: words("It costs R50 a month on Vision One with vercel."))
        let keywords = cues.flatMap(\.words).filter(\.isKeyword).map(\.text)
        XCTAssertEqual(keywords, ["R50", "Vision", "One", "vercel."])
    }

    func testFixesMzansiSpelling() {
        let cues = CaptionBuilder(layout: .subtitle).cues(for: words("That braai was lacker!"))
        XCTAssertEqual(cues[0].text, "That braai was lekker!")
        let off = CaptionBuilder(layout: .subtitle, mzansiSpelling: false).cues(for: words("lacker"))
        XCTAssertEqual(off[0].text, "lacker")
    }

    func testEmptyInput() {
        XCTAssertTrue(CaptionBuilder(layout: .subtitle).cues(for: [CaptionWord]()).isEmpty)
    }

    func testBuildsFromATranscript() {
        let transcript = Transcript(
            language: "en", engine: "test", audioTrack: "mic", duration: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            segments: [TranscriptSegment(words: [
                TranscriptWord(id: 0, text: "Hello", start: 0, end: 0.4),
                TranscriptWord(id: 1, text: "Mzansi.", start: 0.4, end: 0.9),
            ])]
        )
        let cues = CaptionBuilder(layout: .subtitle).cues(for: transcript)
        XCTAssertEqual(cues.map(\.text), ["Hello Mzansi."])
    }

    func testFollowsTheEditList() {
        let transcript = Transcript(
            language: "en", engine: "test", audioTrack: "mic", duration: 2,
            createdAt: Date(timeIntervalSince1970: 0),
            segments: [TranscriptSegment(words: [
                TranscriptWord(id: 0, text: "Ship", start: 0, end: 0.5),
                TranscriptWord(id: 1, text: "um,", start: 0.5, end: 1.0),
                TranscriptWord(id: 2, text: "it.", start: 1.0, end: 1.5),
            ])]
        )
        var edits = EditList(sourceDuration: 2)
        _ = edits.add(Cut(span: TimeSpan(start: 0.5, end: 1.0), reason: Cut.Reason.filler))
        let cues = CaptionBuilder(layout: .subtitle).cues(for: transcript, edits: edits)
        XCTAssertEqual(cues.map(\.text), ["Ship it."])
        XCTAssertEqual(cues[0].words[1].start, 0.5, accuracy: 0.0001)

        // A proposed cut changes nothing until it is accepted.
        var proposed = EditList(sourceDuration: 2)
        _ = proposed.add(Cut(span: TimeSpan(start: 0.5, end: 1.0), reason: Cut.Reason.filler, state: .proposed))
        XCTAssertEqual(CaptionBuilder(layout: .subtitle).cues(for: transcript, edits: proposed).map(\.text), ["Ship um, it."])
    }
}

final class TakeCaptionsTests: XCTestCase {
    func testWritesFilesForATake() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = Take(folder: folder)
        let transcript = Transcript(
            language: "en", engine: "test", duration: 2,
            segments: [TranscriptSegment(words: [
                TranscriptWord(id: 0, text: "Hello", start: 0, end: 0.4),
                TranscriptWord(id: 1, text: "there.", start: 0.4, end: 0.9),
            ])]
        )
        try transcript.write(to: take.transcriptURL)

        let settings = CaptionSettings(style: .wordByWord, position: 0.3)
        try take.saveCaptionSettings(settings)
        XCTAssertEqual(take.loadCaptionSettings(), settings)

        let files = try take.writeCaptionFiles(settings: settings, to: folder)
        XCTAssertEqual(files.map(\.lastPathComponent), ["captions.srt", "captions.vtt"])
        XCTAssertTrue(try String(contentsOf: files[0], encoding: .utf8).contains("Hello there."))
    }
}

final class CaptionTrackTests: XCTestCase {
    func testFindsTheCueOnScreen() {
        let track = CaptionTrack(cues: [
            CaptionCue(start: 0, end: 1, lines: [[CaptionWord(text: "a", start: 0, end: 1)]]),
            CaptionCue(start: 2, end: 3, lines: [[CaptionWord(text: "b", start: 2, end: 3)]]),
        ])
        XCTAssertEqual(track.cue(at: 0.5)?.text, "a")
        XCTAssertNil(track.cue(at: 1.5))
        XCTAssertEqual(track.cue(at: 2)?.text, "b")
        XCTAssertNil(track.cue(at: 3))
        XCTAssertNil(track.cue(at: -1))
    }

    func testSpokenWord() {
        let cue = CaptionCue(start: 0, end: 1.5, lines: [words("one two three", step: 0.5)])
        XCTAssertNil(cue.spokenWordIndex(at: -0.1))
        XCTAssertEqual(cue.spokenWordIndex(at: 0.1), 0)
        XCTAssertEqual(cue.spokenWordIndex(at: 0.7), 1)
        XCTAssertEqual(cue.spokenWordIndex(at: 1.4), 2)
    }
}

final class SubtitleFileTests: XCTestCase {
    private let cues = [
        CaptionCue(start: 0, end: 1.5, lines: [[
            CaptionWord(text: "Hello", start: 0, end: 0.6),
            CaptionWord(text: "world.", start: 0.6, end: 1.2),
        ]]),
        CaptionCue(start: 3725.0456, end: 3727, lines: [
            [CaptionWord(text: "I", start: 3725.0456, end: 3725.2)],
            [CaptionWord(text: "<3", start: 3725.2, end: 3726)],
        ]),
    ]

    func testSRT() {
        XCTAssertEqual(SubtitleFile.srt(cues), """
        1
        00:00:00,000 --> 00:00:01,500
        Hello world.

        2
        01:02:05,046 --> 01:02:07,000
        I
        <3


        """)
    }

    func testVTT() {
        XCTAssertEqual(SubtitleFile.vtt(cues), """
        WEBVTT

        00:00:00.000 --> 00:00:01.500
        Hello world.

        01:02:05.046 --> 01:02:07.000
        I
        &lt;3


        """)
    }

    func testVTTWordTimings() {
        let vtt = SubtitleFile.vtt([cues[0]], wordTimings: true)
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello <00:00:00.600>world.\n\n")
    }

    func testWritesFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try SubtitleFile.write(cues, format: .srt, to: folder)
        XCTAssertEqual(url.lastPathComponent, "captions.srt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), SubtitleFile.srt(cues))
    }
}

final class CaptionStyleTests: XCTestCase {
    func testStylesFollowTheDesignSystem() {
        XCTAssertEqual(CaptionStyle.allCases.map(\.title), ["Subtitle", "Word by word", "Keyword", "Bold pop"])
        XCTAssertFalse(CaptionStyle.subtitle.highlightsSpokenWord)
        XCTAssertFalse(CaptionStyle.wordByWord.colorsKeywords)
        XCTAssertTrue(CaptionStyle.keyword.colorsKeywords)
        XCTAssertEqual(CaptionStyle.keyword.layout, .wordByWord)
    }

    func testOnlyBoldPopPops() {
        XCTAssertEqual(CaptionStyle.boldPop.scale(secondsSinceWordStart: 0), 1.12, accuracy: 0.0001)
        XCTAssertEqual(CaptionStyle.boldPop.scale(secondsSinceWordStart: 0.2), 1)
        XCTAssertEqual(CaptionStyle.subtitle.scale(secondsSinceWordStart: 0), 1)
    }

    func testEnergyDial() {
        XCTAssertEqual(CaptionStyle.forEnergy(0), .subtitle)
        XCTAssertEqual(CaptionStyle.forEnergy(1), .keyword)
        XCTAssertEqual(CaptionStyle.forEnergy(2), .boldPop)
    }

    func testAdjustableSizePositionAndWords() {
        var settings = CaptionSettings(style: .wordByWord)
        XCTAssertEqual(settings.bottomInset(isVertical: true), 0.26, accuracy: 0.0001)
        settings.position = 0.5
        XCTAssertEqual(settings.bottomInset(isVertical: true), 0.5, accuracy: 0.0001)
        settings.position = 5
        XCTAssertEqual(settings.bottomInset(isVertical: false), 0.9, accuracy: 0.0001)

        settings.sizeScale = 2
        XCTAssertEqual(settings.relativeFontSize, 0.068 * 1.8, accuracy: 0.0001)
        XCTAssertLessThan(settings.layout.maxCharactersPerLine, CaptionLayout.wordByWord.maxCharactersPerLine)

        settings.sizeScale = 1
        settings.wordsAtATime = 1
        XCTAssertEqual(settings.layout.maxWordsPerCue, 1)
        let cues = settings.builder.cues(for: words("one word at a time"))
        XCTAssertEqual(cues.count, 5)
    }

    func testOldSettingsFilesStillOpen() throws {
        let json = Data(#"{"isOn":true,"style":"keyword","burnIn":false}"#.utf8)
        let settings = try JSONDecoder().decode(CaptionSettings.self, from: json)
        XCTAssertEqual(settings.style, .keyword)
        XCTAssertFalse(settings.burnIn)
        XCTAssertEqual(settings.sizeScale, 1)
        XCTAssertNil(settings.position)
    }

    func testSettingsRoundTrip() throws {
        let settings = CaptionSettings(style: .boldPop, burnIn: false, keywordNames: ["Vision One"], sizeScale: 1.3, position: 0.4, wordsAtATime: 2)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(CaptionSettings.self, from: data), settings)
    }
}

final class MzansiLexiconTests: XCTestCase {
    func testFixesKeepPunctuationAndCapitals() {
        XCTAssertEqual(MzansiLexicon.fix("lacker!"), "lekker!")
        XCTAssertEqual(MzansiLexicon.fix("Lacker"), "Lekker")
        XCTAssertEqual(MzansiLexicon.fix("joburg,"), "Joburg,")
        XCTAssertEqual(MzansiLexicon.fix("isizulu"), "isiZulu")
        XCTAssertEqual(MzansiLexicon.fix("hello"), "hello")
    }

    func testVocabularyPrompt() {
        XCTAssertTrue(MzansiLexicon.vocabularyPrompt.contains("Gqeberha"))
    }
}
