import XCTest
@testable import VisionOneKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers every request with the next canned reply and keeps what was sent.
private final class CannedHTTP: HTTPClient, @unchecked Sendable {
    var replies: [(Int, Data)]
    var sent: [URLRequest] = []

    init(_ replies: [(Int, Data)]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let (status, data) = replies.isEmpty ? (200, Data()) : replies.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

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
        // Back to back, and time follows length: same-length words get the same time.
        let words = transcript.words
        XCTAssertEqual(words[0].end, words[1].start, accuracy: 1e-9)
        XCTAssertEqual(words[0].duration, words[1].duration, accuracy: 1e-9)
        let short = Transcript.translated([TranslatedLine(start: 0, end: 2, source: "Go now.", text: "Hamba manje-manje.")],
                                          language: .zulu, engine: "test", duration: 2).words
        XCTAssertGreaterThan(short[1].duration, short[0].duration)
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
        XCTAssertEqual(FillerLexicon.lexicon(for: .english).entries.map(\.tokens), FillerLexicon.standard.entries.map(\.tokens))
    }

    // MARK: ElevenLabs

    func testScribeWordsBecomePieces() throws {
        let json = #"""
        {"language_code": "zul", "words": [
          {"text": "Sawubona", "start": 0.1, "end": 0.6, "type": "word", "logprob": -0.1},
          {"text": " ", "start": 0.6, "end": 0.7, "type": "spacing"},
          {"text": "(laughs)", "start": 0.7, "end": 1.0, "type": "audio_event"},
          {"text": "nonke.", "start": 1.0, "end": 1.4, "type": "word"}
        ]}
        """#
        let result = try ElevenLabsClient.pieces(fromScribe: Data(json.utf8))
        XCTAssertEqual(result.language, "zul")
        XCTAssertEqual(result.pieces.map(\.text), ["Sawubona", "nonke."])
        XCTAssertTrue(result.pieces.allSatisfy(\.startsWord))
        XCTAssertEqual(result.pieces[0].confidence ?? 0, exp(-0.1), accuracy: 1e-9)
    }

    func testDubStatus() throws {
        XCTAssertEqual(try ElevenLabsClient.dubStatus(from: Data(#"{"status": "dubbing"}"#.utf8)), .working)
        XCTAssertEqual(try ElevenLabsClient.dubStatus(from: Data(#"{"status": "dubbed"}"#.utf8)), .done)
        XCTAssertEqual(try ElevenLabsClient.dubStatus(from: Data(#"{"status": "failed", "error": "No speech"}"#.utf8)),
                       .failed("No speech"))
    }

    func testScribeAsksFirstAndSendsTheLanguage() async throws {
        let reply = Data(#"{"language_code": "afr", "words": [{"text": "Hallo", "start": 0, "end": 0.5, "type": "word"}]}"#.utf8)
        let http = CannedHTTP([(200, reply)])
        let approver = RecordingApprover(.allowOnce)
        let client = ElevenLabsClient(apiKey: "key", gate: OutboundGate(approver: approver), http: http)
        let transcript = try await client.transcribe(audio: Data([1, 2, 3]), fileName: "voice.wav", mimeType: "audio/wav",
                                                     seconds: 1, language: .afrikaans)
        XCTAssertEqual(transcript.language, "af")
        XCTAssertEqual(transcript.words.map(\.text), ["Hallo"])
        let asked = await approver.asked
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.kind, .audio)
        let body = String(decoding: http.sent.first?.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("afr"))
        XCTAssertTrue(body.contains("scribe_v2"))
        XCTAssertEqual(http.sent.first?.url?.path, "/v1/speech-to-text")
    }

    func testDubRefusesLanguagesElevenLabsDoesNotDub() async {
        let client = ElevenLabsClient(apiKey: "key", gate: OutboundGate(approver: FixedApprover(.allowOnce)), http: CannedHTTP([]))
        do {
            _ = try await client.startDub(audio: Data(), fileName: "a.m4a", mimeType: "audio/mp4", seconds: 1,
                                         from: .english, to: .xhosa, name: "x")
            XCTFail("isiXhosa can't be dubbed")
        } catch {
            XCTAssertEqual(error as? AIError, .unavailable(.elevenLabs, "ElevenLabs doesn't dub isiXhosa yet. Captions still work."))
        }
    }

    func testScribeUploadIsMonoWAV() {
        let data = WAVFile.data(samples: [0, 1, -1], sampleRate: 16_000, channels: 1)
        XCTAssertEqual(data.count, 44 + 6)
        XCTAssertEqual(data[22], 1)  // channels
        XCTAssertEqual(data[44 + 2], 0xFF)  // 32767 little endian: FF 7F
        XCTAssertEqual(data[44 + 3], 0x7F)
    }
}
