import XCTest
@testable import VisionOneKit

private func word(_ id: Int, _ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(id: id, text: text, start: start, end: end)
}

final class LanguagesTests: XCTestCase {
    // MARK: Languages

    func testElevenSpokenLanguages() {
        XCTAssertEqual(SALanguage.allCases.count, 11)
        XCTAssertEqual(Set(SALanguage.allCases.map(\.code)).count, 11)
        XCTAssertEqual(SALanguage.captionTargets.count, 10)
        XCTAssertFalse(SALanguage.captionTargets.contains(.english))
    }

    func testCodesAndNamesAsPeopleWriteThem() {
        XCTAssertEqual(SALanguage(code: "zu"), .zulu)
        XCTAssertEqual(SALanguage(code: "zul"), .zulu)
        XCTAssertEqual(SALanguage(code: "zu-ZA"), .zulu)
        XCTAssertEqual(SALanguage(code: "isiZulu"), .zulu)
        XCTAssertEqual(SALanguage(code: "Zulu"), .zulu)
        XCTAssertEqual(SALanguage(code: "Northern Sotho"), .sepedi)
        XCTAssertEqual(SALanguage(code: "nso"), .sepedi)
        XCTAssertEqual(SALanguage(code: "Sesotho"), .sesotho)
        XCTAssertEqual(SALanguage(code: "Tshivenda"), .tshivenda)
        XCTAssertEqual(SALanguage(code: "af_ZA"), .afrikaans)
        XCTAssertNil(SALanguage(code: "fr"))
        XCTAssertNil(SALanguage(code: ""))
    }

    func testSupportMatchesTheProviderDocs() {
        // ElevenLabs Dubbing v2 doesn't list isiXhosa or isiNdebele.
        XCTAssertFalse(SALanguage.xhosa.support.dub.quality.isAvailable)
        XCTAssertFalse(SALanguage.ndebele.support.dub.quality.isAvailable)
        XCTAssertEqual(SALanguage.allCases.filter { $0.support.dub.quality.isAvailable }.count, 9)
        // Scribe: Afrikaans, isiZulu, isiXhosa and Sepedi among SA languages.
        let scribe = SALanguage.captionTargets.filter { $0.support.transcribeCloud.quality.isAvailable }
        XCTAssertEqual(Set(scribe), [.afrikaans, .zulu, .xhosa, .sepedi])
        // Eleven v4 speaks Afrikaans and English only.
        XCTAssertEqual(Set(SALanguage.allCases.filter { $0.support.speak.quality.isAvailable }), [.english, .afrikaans])
        // Only English is transcribed on the Mac today.
        XCTAssertEqual(SALanguage.allCases.filter { $0.support.transcribeOnMac.quality.isAvailable }, [.english])
        // Every language can get captions.
        XCTAssertTrue(SALanguage.allCases.allSatisfy { $0.support.translate.quality.isAvailable })
    }

    func testFairAndRoughAskForASpeaker() {
        XCTAssertFalse(SALanguage.afrikaans.support.translate.quality.wantsSpeakerCheck)
        XCTAssertTrue(SALanguage.zulu.support.translate.quality.wantsSpeakerCheck)
        XCTAssertTrue(SALanguage.tshivenda.support.translate.quality.wantsSpeakerCheck)
        XCTAssertLessThan(LanguageQuality.rough, .fair)
    }

    // MARK: Translated transcript

    func testTranslatedLinesSpreadAcrossTheSentence() {
        let lines = [TranslatedLine(start: 1, end: 3, source: "Pick your rank.", text: "Khetha irenki yakho.")]
        let transcript = Transcript.translated(lines, language: .zulu, engine: "test", duration: 10)
        XCTAssertEqual(transcript.language, "zu")
        XCTAssertEqual(transcript.words.map(\.text), ["Khetha", "irenki", "yakho."])
        XCTAssertEqual(transcript.words.first?.start, 1)
        XCTAssertEqual(transcript.words.last?.end, 3)
        // Back to back, longer words get longer.
        let words = transcript.words
        XCTAssertEqual(words[0].end, words[1].start, accuracy: 1e-9)
        XCTAssertGreaterThan(words[1].duration, words[0].duration)
        XCTAssertEqual(Set(words.map(\.id)).count, 3)
    }

    func testTranslatedCaptionsDropCutWords() {
        let lines = [
            TranslatedLine(start: 0, end: 2, source: "One.", text: "Kunye."),
            TranslatedLine(start: 4, end: 6, source: "Two.", text: "Kubili."),
        ]
        let transcript = Transcript.translated(lines, language: .zulu, engine: "test", duration: 6)
        var edits = EditList(sourceDuration: 6)
        _ = edits.add(Cut(span: TimeSpan(start: 3.5, end: 6.0), reason: Cut.Reason.word, state: .accepted))
        let cues = CaptionBuilder(layout: .subtitle).cues(for: transcript, edits: edits)
        XCTAssertEqual(cues.map(\.text), ["Kunye."])
    }

    func testCaptionSettingsKeepLanguageAndReadOldFiles() throws {
        var settings = CaptionSettings()
        settings.language = .afrikaans
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(CaptionSettings.self, from: data).language, .afrikaans)
        let old = try JSONDecoder().decode(CaptionSettings.self, from: Data(#"{"isOn": true}"#.utf8))
        XCTAssertNil(old.language)
    }

    func testTakeUsesTheChosenTranslation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = Take(folder: folder)
        let spoken = Transcript(language: "en", engine: "test", duration: 2,
                                segments: [TranscriptSegment(words: [word(0, "Hello.", 0, 1)])])
        try spoken.write(to: take.transcriptURL)
        let file = TranslationFile(language: .afrikaans, engine: "fake",
                                   lines: [TranslatedLine(start: 0, end: 1, source: "Hello.", text: "Hallo.")])
        try take.saveTranslation(file, duration: 2)
        XCTAssertEqual(take.captionLanguages(), [.afrikaans])
        XCTAssertEqual(try take.captionTranscript(language: nil).text, "Hello.")
        XCTAssertEqual(try take.captionTranscript(language: .afrikaans).text, "Hallo.")
        // A language with no file falls back to what was said.
        XCTAssertEqual(try take.captionTranscript(language: .zulu).text, "Hello.")
        take.removeTranslation(.afrikaans)
        XCTAssertEqual(take.captionLanguages(), [])
    }

    // MARK: Translator

    func testBatchesStayUnderTheLimit() {
        let sentences = (0..<10).map {
            SpokenSentence(index: $0, wordIDs: [$0], text: String(repeating: "a", count: 100), start: Double($0), end: Double($0) + 1)
        }
        let batches = CaptionTranslator.batches(sentences, limit: 250)
        XCTAssertEqual(batches.flatMap { $0 }.count, 10)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 3 })
    }

    func testRequestNamesTheLanguageAndKeepsNames() {
        let sentence = SpokenSentence(index: 0, wordIDs: [0], text: "Pay with SnapScan.", start: 0, end: 1)
        let request = CaptionTranslator.request(for: [sentence], to: .sepedi, keep: ["RankRide", "SnapScan"])
        XCTAssertTrue(request.instructions.contains("Sesotho sa Leboa"))
        XCTAssertTrue(request.instructions.contains("RankRide, SnapScan"))
        XCTAssertEqual(request.input, "1. Pay with SnapScan.")
        XCTAssertEqual(request.task, .translateCaptions)
    }

    func testParseTrustsNumbersAndRejectsGaps() throws {
        let batch = [
            SpokenSentence(index: 0, wordIDs: [0], text: "One.", start: 0, end: 1),
            SpokenSentence(index: 1, wordIDs: [1], text: "Two.", start: 1, end: 2),
        ]
        let ok = AIResponse(text: #"```json {"lines": [{"n": 2, "text": "Twee."}, {"n": 1, "text": "Een."}]} ```"#,
                            provider: .chatGPT, model: "m")
        let lines = try CaptionTranslator.parse(ok, batch: batch)
        XCTAssertEqual(lines.map(\.text), ["Een.", "Twee."])
        XCTAssertEqual(lines[1].start, 1)
        let short = AIResponse(text: #"{"lines": [{"n": 1, "text": "Een."}]}"#, provider: .chatGPT, model: "m")
        XCTAssertThrowsError(try CaptionTranslator.parse(short, batch: batch))
    }

    func testTranslateSkipsOnDeviceAndKeepsHandFixes() async throws {
        let device = FakeProvider(.appleOnDevice, rung: .onDevice, leavesDevice: false, contextTokens: 4096)
        let cloud = FakeProvider(.chatGPT, rung: .chatGPT) { request in
            let count = request.input.split(separator: "\n").count
            let lines = (1...count).map { #"{"n": \#($0), "text": "zu \#($0)"}"# }.joined(separator: ",")
            return #"{"lines": [\#(lines)]}"#
        }
        let ladder = AILadder(providers: [device, cloud], gate: OutboundGate(approver: FixedApprover(.allowOnce)))
        let transcript = Transcript(language: "en", engine: "test", duration: 4, segments: [
            TranscriptSegment(words: [word(0, "Pick", 0, 0.5), word(1, "your", 0.5, 0.8), word(2, "rank.", 0.8, 1.2)]),
            TranscriptSegment(words: [word(3, "See", 2, 2.4), word(4, "the", 2.4, 2.6), word(5, "queue.", 2.6, 3)]),
        ])
        let previous = TranslationFile(language: .zulu, engine: "old", lines: [
            TranslatedLine(start: 0, end: 1.2, source: "Pick your rank.", text: "Khetha irenki yakho.", edited: true),
        ])
        let file = try await CaptionTranslator(ladder: ladder).translate(transcript, to: .zulu, previous: previous)
        XCTAssertEqual(device.calls, 0)
        XCTAssertEqual(cloud.calls, 1)
        XCTAssertEqual(file.lines.map(\.text), ["Khetha irenki yakho.", "zu 1"])
        XCTAssertTrue(file.lines[0].edited)
        XCTAssertEqual(file.lines[1].start, 2)
    }

    func testReceiptAsksForASpeaker() {
        let zulu = TranslationFile(language: .zulu, engine: "x", lines: [TranslatedLine(start: 0, end: 1, source: "a", text: "b")])
        XCTAssertTrue(AgentReceipt.translation(zulu).contains("Ask a isiZulu speaker") || AgentReceipt.translation(zulu).contains("isiZulu speaker"))
        let af = TranslationFile(language: .afrikaans, engine: "x", lines: [])
        XCTAssertFalse(AgentReceipt.translation(af).contains("speaker"))
    }

    // MARK: Fillers

    func testFillersPerLanguage() {
        let zulu = FillerLexicon.lexicon(for: .zulu).entries.map { $0.tokens.joined(separator: " ") }
        XCTAssertTrue(zulu.contains("uyabona"))
        XCTAssertTrue(zulu.contains("eish"))
        XCTAssertFalse(zulu.contains("like"))
        let afrikaans = FillerLexicon.lexicon(for: .afrikaans).entries.map { $0.tokens.joined(separator: " ") }
        XCTAssertTrue(afrikaans.contains("jy weet"))
        XCTAssertTrue(afrikaans.contains("ne"))   // "nê", accents folded
        XCTAssertEqual(FillerLexicon.lexicon(for: .english), .standard)
    }
}
