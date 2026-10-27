import XCTest
@testable import VisionOneKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ScriptCoachTests: XCTestCase {
    let rankRide = Script(text: """
    Joburg taxi ranks, without the queue. Pick your rank. See exactly where the queue is, how long the wait will be, and which taxi you'll get, before you leave, so you never stand around in the sun again wondering.
    Pay with SnapScan scan before you get there.
    """)

    func testFlagsALongSentenceAndOffersTwoShorterOnes() {
        let report = ScriptCoach().check(rankRide)
        let long = report.flags.first { $0.kind == .longSentence }
        XCTAssertEqual(long?.line, 2)
        let suggestion = try? XCTUnwrap(long?.suggestion)
        XCTAssertEqual(suggestion?.components(separatedBy: ". ").count, 2)
    }

    func testFlagsARepeatedSoundAndFixesIt() {
        let report = ScriptCoach().check(rankRide)
        let twister = report.flags.first { $0.kind == .tongueTwister && $0.phrase == "SnapScan scan" }
        XCTAssertNotNil(twister)
        let fixed = rankRide.applying(twister!)
        XCTAssertTrue(fixed.text.contains("Pay with SnapScan before"))
        XCTAssertFalse(fixed.text.contains("SnapScan scan"))
    }

    func testFlagsAlliterationButNotLittleWords() {
        let coach = ScriptCoach()
        let twister = coach.check(Script(text: "She sells sea shells by the shore.")).flags
        XCTAssertTrue(twister.contains { $0.kind == .tongueTwister })
        let fine = coach.check(Script(text: "Then they told the team the plan.")).flags
        XCTAssertFalse(fine.contains { $0.kind == .tongueTwister })
    }

    func testFlagsUnknownAcronymsAndBigNumbers() {
        let flags = ScriptCoach().check(Script(text: "Our SDLC tool saved R1250000 for the team. Try it at rankride.co.za.")).flags
        XCTAssertTrue(flags.contains { $0.kind == .jargon && $0.phrase == "SDLC" })
        let number = flags.first { $0.kind == .number }
        XCTAssertEqual(number?.suggestion, "R1.25 million")
        XCTAssertFalse(ScriptCoach().check(Script(text: "AI on your Mac. Try it today.")).flags.contains { $0.kind == .jargon })
    }

    func testAsksForAnEndingWithOneAsk() {
        XCTAssertTrue(ScriptCoach().check(rankRide).flags.contains { $0.kind == .ending })
        let withAsk = Script(text: "Skip the queue. Try it at rankride.co.za.")
        XCTAssertFalse(ScriptCoach().check(withAsk).flags.contains { $0.kind == .ending })
    }

    func testLengthUsesThePaceAndTags() {
        let script = Script(text: String(repeating: "word ", count: 150) + "[long pause]")
        let length = ScriptCoach().length(of: script, pace: SpeakingPace(wordsPerMinute: 150, takes: 3), target: 30...60)
        XCTAssertEqual(length.seconds, 61, accuracy: 0.01)
        XCTAssertEqual(length.fit, .long)
        XCTAssertEqual(length.text, "1:01")
    }

    func testRewriteRequestOnlySendsFlaggedLines() throws {
        let coach = ScriptCoach()
        let report = coach.check(rankRide)
        let request = try XCTUnwrap(coach.rewriteRequest(rankRide, flags: report.flags))
        XCTAssertEqual(request.task, ScriptCoach.rewriteTask)
        XCTAssertFalse(request.input.contains("Pick your rank"))
        let rewritten = coach.applying([.init(line: 2, say: "See the queue before you leave.")], to: report)
        XCTAssertEqual(rewritten.flags.first { $0.kind == .longSentence }?.suggestion, "See the queue before you leave.")
    }
}

final class DeliveryMarkupTests: XCTestCase {
    func testAddsToneAndPausesAndKeepsUserTags() {
        let script = Script(text: "Skip the queue.\nPick your rank.")
        XCTAssertEqual(DeliveryMarkup.reading(script, tone: .lively), "[upbeat] Skip the queue. [pause] Pick your rank.")
        let tagged = Script(text: "[calm] Skip the [pause] queue.")
        XCTAssertEqual(DeliveryMarkup.reading(tagged, tone: .lively), "[calm] Skip the [pause] queue.")
        XCTAssertEqual(DeliveryMarkup.plain(tagged), "Skip the queue.")
    }

    func testSlowsLongLines() {
        let script = Script(text: "One. Two words here.")
        let flag = ScriptFlag(kind: .longSentence, line: 1, title: "", detail: "")
        XCTAssertEqual(DeliveryMarkup.reading(script, tone: .calm, flags: [flag]), "[calm] One. [slower] Two words here.")
    }

    func testAudioTags() {
        XCTAssertEqual(AudioTags.tags(in: "[Upbeat] hi [pause] there"), ["upbeat", "pause"])
        XCTAssertEqual(AudioTags.pauseSeconds(in: "[pause] a [long pause]"), 1.6, accuracy: 0.001)
    }
}

final class RehearsalTests: XCTestCase {
    func testPitchTrackerFindsASine() throws {
        let rate = 16_000.0
        let tracker = PitchTracker(sampleRate: rate)
        let frame = (0..<tracker.frameLength).map { Float(0.3 * sin(2 * Double.pi * 180 * Double($0) / rate)) }
        let hz = try XCTUnwrap(tracker.pitch(of: frame))
        XCTAssertEqual(hz, 180, accuracy: 3)
        XCTAssertNil(tracker.pitch(of: [Float](repeating: 0, count: tracker.frameLength)))
    }

    func testPaceUmsAndPauses() {
        // 20 words over 8 s, a 0.5 s pause after every word, one um.
        var words: [HeardWord] = (0..<20).map { HeardWord(text: "word", start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3) }
        words.insert(HeardWord(text: "um", start: 8.1, end: 8.3), at: 20)
        var monitor = RehearsalMonitor()
        monitor.setWords(words)
        let reading = monitor.reading(at: 8.3)
        XCTAssertEqual(reading.ums, 1)
        // Counts up to now while the voice has only just stopped.
        XCTAssertEqual(reading.pace ?? 0, 20 / 8.3 * 60, accuracy: 1)
        XCTAssertNil(reading.pause, "Gaps of 0.1 s are running speech, not pauses")
    }

    func testEnergyIsLowForAFlatVoiceAndHighForAMovingOne() throws {
        let flat = (0..<40).map { VoiceFrame(time: Double($0) * 0.05, levelDB: -20, pitchHz: 150) }
        let moving = (0..<40).map { i in
            VoiceFrame(time: Double(i) * 0.05, levelDB: i % 2 == 0 ? -12 : -28, pitchHz: i % 3 == 0 ? 120 : 220)
        }
        XCTAssertLessThan(try XCTUnwrap(RehearsalMonitor.energy(flat)), 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(RehearsalMonitor.energy(moving)), 0.8)
        XCTAssertNil(RehearsalMonitor.energy(Array(flat.prefix(3))))
    }

    func testTargetsMoveToTheSpeakersOwnPace() {
        XCTAssertEqual(RehearsalTargets.around(SpeakingPace()).pace, SpeakingPace.comfortable)
        XCTAssertEqual(RehearsalTargets.around(SpeakingPace(wordsPerMinute: 170, takes: 4)).pace, 150...185)
    }

    func testLearnsPaceFromTakes() {
        // 30 words in 10 s of talking: 180 a minute.
        let words = (0..<30).map { TranscriptWord(id: $0, text: $0 % 10 == 9 ? "word." : "word",
                                                  start: Double($0) / 3, end: Double($0) / 3 + 0.3) }
        let transcript = Transcript(language: "en", engine: "test", duration: 10, segments: [TranscriptSegment(words: words)])
        let pace = SpeakingPace.learn(from: [transcript])
        XCTAssertTrue(pace.isLearned)
        XCTAssertEqual(pace.wordsPerMinute, 184, accuracy: 6)
    }
}

final class CoachNotesTests: XCTestCase {
    let script = Script(text: "Joburg taxi ranks, without the queue. Pick your rank and see the queue before you leave. Pay with SnapScan before you get there. Try it at rankride.co.za.")

    /// Says each line's words evenly over `seconds`, from `start`.
    func say(_ line: Int, from start: Double, seconds: Double, um: Bool = false) -> [HeardWord] {
        let words = script.lines[line].text.split(separator: " ").map(String.init)
        let step = seconds / Double(words.count)
        var heard = words.enumerated().map { HeardWord(text: $0.element, start: start + Double($0.offset) * step,
                                                       end: start + Double($0.offset) * step + step * 0.8) }
        if um { heard.insert(HeardWord(text: "um,", start: start + step * 2.85, end: start + step * 2.95), at: 3) }
        return heard
    }

    func testThreeNotesTiedToLines() throws {
        let words = say(0, from: 0, seconds: 2.6, um: true)
            + say(1, from: 3, seconds: 4.5)
            + say(2, from: 9, seconds: 1.8) // 7 words in 1.8 s: about 240 a minute
            + say(3, from: 11.5, seconds: 2)
        let review = CoachNotes.review(script: script, words: words, frames: [])
        XCTAssertEqual(review.notes.count, 3)
        XCTAssertEqual(review.notes.filter(\.isStrength).count, 1)
        let fast = try XCTUnwrap(review.notes.first)
        XCTAssertEqual(fast.kind, .tooFast)
        XCTAssertEqual(fast.line, 2)
        XCTAssertEqual(fast.title, "Slow down on the SnapScan line")
        XCTAssertTrue(review.notes.contains { $0.kind == .ums && $0.title == "One um, in the opening" })
        XCTAssertEqual(review.focusLine, 2)
    }

    func testNoticesASkippedLine() {
        let words = say(0, from: 0, seconds: 2.5) + say(2, from: 3, seconds: 2.5) + say(3, from: 6, seconds: 2)
        let review = CoachNotes.review(script: script, words: words, frames: [])
        XCTAssertEqual(review.notes.first?.kind, .skipped)
        XCTAssertEqual(review.notes.first?.line, 1)
    }

    func testAllGoodGivesStrengths() {
        let words = say(0, from: 0, seconds: 2.5) + say(1, from: 3, seconds: 4.5)
            + say(2, from: 9, seconds: 2.6) + say(3, from: 12, seconds: 1.6)
        let review = CoachNotes.review(script: script, words: words, frames: [])
        XCTAssertTrue(review.notes.allSatisfy(\.isStrength))
        XCTAssertTrue(review.notes.contains { $0.kind == .strongEnding })
    }

    func testCoachContextCarriesTheNotes() {
        let words = say(0, from: 0, seconds: 2.5) + say(1, from: 3, seconds: 4.5)
            + say(2, from: 9, seconds: 1.8) + say(3, from: 12, seconds: 2)
        let context = CoachContext(script: script, review: CoachNotes.review(script: script, words: words, frames: []))
        XCTAssertTrue(context.script.hasPrefix("1. Joburg taxi ranks"))
        XCTAssertTrue(context.notes.contains("Slow down"))
        XCTAssertEqual(context.focus, "the SnapScan line")
    }
}

/// Answers every request with one canned reply and keeps what was sent.
final class CoachFakeHTTP: HTTPClient, @unchecked Sendable {
    var sent: [URLRequest] = []
    let status: Int
    let body: Data
    init(status: Int = 200, json: String) {
        self.status = status
        self.body = Data(json.utf8)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class ElevenLabsTests: XCTestCase {
    func testWordTimingsSkipTags() {
        let chars = Array("[upbeat] Hi there").map(String.init)
        let starts = chars.indices.map { Double($0) * 0.1 }
        let words = SpokenAudio.words(characters: chars, starts: starts, ends: starts.map { $0 + 0.1 })
        XCTAssertEqual(words.map(\.text), ["Hi", "there"])
        XCTAssertEqual(words[0].start, 0.9, accuracy: 0.001)
        XCTAssertEqual(words[1].end, 1.7, accuracy: 0.001)
    }

    func testSpeakAsksFirstAndSendsTheKey() async throws {
        let audio = Data("ID3fake".utf8).base64EncodedString()
        let http = CoachFakeHTTP(json: #"{"audio_base64": "\#(audio)", "alignment": {"characters": ["H","i"], "character_start_times_seconds": [0, 0.1], "character_end_times_seconds": [0.1, 0.2]}}"#)
        let approver = RecordingApprover(.allowOnce)
        let client = ElevenLabsClient(apiKey: "k", gate: OutboundGate(approver: approver), http: http)
        let spoken = try await client.speak("[upbeat] Hi", voiceID: "v1")
        XCTAssertEqual(spoken.words.map(\.text), ["Hi"])
        XCTAssertEqual(String(decoding: spoken.audio, as: UTF8.self), "ID3fake")
        let request = try XCTUnwrap(http.sent.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertEqual(request.url?.path, "/v1/text-to-speech/v1/with-timestamps")
        let asked = await approver.asked
        XCTAssertEqual(asked.first?.task, .coachHear)
        XCTAssertEqual(asked.first?.destination, "api.elevenlabs.io")
    }

    func testANoSendsNothing() async {
        let http = CoachFakeHTTP(json: "{}")
        let client = ElevenLabsClient(apiKey: "k", gate: OutboundGate(approver: FixedApprover(.deny)), http: http)
        do {
            _ = try await client.isolate(audio: Data([1, 2, 3]), fileName: "mic.m4a", seconds: 112)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AIError, .notApproved)
        }
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testAudioCanBeAllowedForTheSession() async throws {
        let approver = RecordingApprover(.allowForSession)
        let gate = OutboundGate(approver: approver)
        let audio = OutboundRequest(kind: .audio, provider: .elevenLabs, providerName: "ElevenLabs", destination: "x",
                                    task: .voiceIsolate, summary: "", payload: "")
        try await gate.check(audio)
        try await gate.check(audio)
        let asked = await approver.asked.count
        XCTAssertEqual(asked, 1)
    }

    func testErrorsAndMissingKey() async {
        let http = CoachFakeHTTP(status: 401, json: #"{"detail": {"message": "Invalid API key"}}"#)
        let client = ElevenLabsClient(apiKey: "bad", gate: nil, http: http)
        do { _ = try await client.voices(); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .http(.elevenLabs, status: 401, message: "Invalid API key"))
        }
        let none = ElevenLabsClient(apiKey: "", gate: nil, http: http)
        do { _ = try await none.credits(); XCTFail() } catch {
            XCTAssertEqual(error as? AIError, .unavailable(.elevenLabs, "Add an ElevenLabs API key"))
        }
    }

    func testMultipartBody() {
        var form = MultipartForm(boundary: "B")
        form.addField(name: "name", value: "Lee")
        form.addFile(name: "files", fileName: "a.m4a", mimeType: "audio/mp4", data: Data("x".utf8))
        let text = String(decoding: form.data, as: UTF8.self)
        XCTAssertEqual(text, "--B\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nLee\r\n--B\r\nContent-Disposition: form-data; name=\"files\"; filename=\"a.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nx\r\n--B--\r\n")
    }

    func testCoachWire() throws {
        let start = CoachWire.start(CoachContext(script: "s", notes: "n", focus: "f"))
        XCTAssertEqual(start, #"{"dynamic_variables":{"focus":"f","notes":"n","script":"s"},"type":"conversation_initiation_client_data"}"#)
        XCTAssertEqual(CoachWire.pong(7), #"{"event_id":7,"type":"pong"}"#)
        XCTAssertEqual(CoachWire.parse(#"{"type":"ping","ping_event":{"event_id":3,"ping_ms":50}}"#), .ping(eventID: 3, delayMS: 50))
        XCTAssertEqual(CoachWire.parse(#"{"type":"agent_response","agent_response_event":{"agent_response":"Nice."}}"#), .agentSaid("Nice."))
        XCTAssertEqual(CoachWire.parse(#"{"type":"audio","audio_event":{"audio_base_64":"AAE=","event_id":2}}"#), .audio(Data([0, 1]), eventID: 2))
        XCTAssertEqual(CoachWire.sampleRate(of: "pcm_22050"), 22_050)
        let config = CoachAgentConfig(voiceID: "v")
        let tts = (config.body["conversation_config"] as? [String: Any])?["tts"] as? [String: Any]
        XCTAssertEqual(tts?["voice_id"] as? String, "v")
        XCTAssertTrue(config.prompt.contains("{{script}}"))
    }
}

final class VoiceEditsTests: XCTestCase {
    func fix(_ wordID: Int, _ start: Double, _ end: Double, duration: Double = 0.3) -> VoiceEdits.WordFix {
        VoiceEdits.WordFix(wordID: wordID, start: start, end: end, original: "bether", replacement: "better",
                           file: "fix-\(wordID).mp3", duration: duration, voiceID: "v")
    }

    func testOnlyKeptFixesPlayAndTheyFollowCuts() {
        var edits = VoiceEdits()
        let a = fix(4, 10, 10.4), b = fix(9, 20, 20.4)
        edits.propose(a)
        edits.propose(b)
        edits.keep(a.id)
        XCTAssertEqual(edits.aiSpokenWordIDs, [4, 9])
        // Cut 2 s to 4 s: the word moves 2 s earlier.
        let timeline = ExportTimeline(keep: [0..<2, 4..<30], sourceDuration: 30, frameRate: 30)
        let placements = edits.placements(on: timeline)
        XCTAssertEqual(placements.count, 1)
        XCTAssertEqual(placements[0].mute.start, 8, accuracy: 0.05)
        XCTAssertEqual(placements[0].at, 8.05, accuracy: 0.05)
        XCTAssertEqual(edits.disclosure, "One word in this video was re-said by an AI copy of the speaker's own voice, made with their consent.")
    }

    func testAWordInsideACutIsSkipped() {
        var edits = VoiceEdits()
        let a = fix(4, 3, 3.4)
        edits.propose(a)
        edits.keep(a.id)
        let timeline = ExportTimeline(keep: [0..<2, 4..<30], sourceDuration: 30, frameRate: 30)
        XCTAssertTrue(edits.placements(on: timeline).isEmpty)
    }

    func testRoundTripAndUndo() throws {
        var edits = VoiceEdits(cleanVoice: .init(file: "voice-clean.mp3"))
        let a = fix(1, 1, 1.2)
        edits.propose(a)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID()).json")
        try edits.write(to: url)
        XCTAssertEqual(VoiceEdits.load(from: url).fixes.first?.wordID, 1)
        XCTAssertEqual(edits.undo(a.id), "fix-1.mp3")
        XCTAssertTrue(edits.fixes.isEmpty)
        XCTAssertEqual(AudioFileKind.fileExtension(for: Data("RIFF0000WAVE".utf8)), "wav")
        XCTAssertEqual(AudioFileKind.fileExtension(for: Data([0xFF, 0xFB, 0, 0])), "mp3")
    }
}
