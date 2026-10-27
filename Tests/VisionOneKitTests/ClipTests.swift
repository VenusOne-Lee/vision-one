import XCTest
@testable import VisionOneKit

/// A transcript from sentences, each word 0.3 s long with 0.05 s
/// between words and `gap` seconds between sentences.
func makeTranscript(_ sentences: [String], gap: Double = 0.3, start: Double = 1) -> Transcript {
    var words: [TranscriptWord] = []
    var t = start
    var id = 0
    for sentence in sentences {
        for text in sentence.split(separator: " ") {
            words.append(TranscriptWord(id: id, text: String(text), start: t, end: t + 0.3))
            id += 1
            t += 0.35
        }
        t += gap
    }
    return Transcript(language: "en", engine: "test", duration: t + 1,
                      segments: [TranscriptSegment(words: words)])
}

final class ClipListTests: XCTestCase {
    func testProposeSkipsClipsThatMostlyOverlap() {
        var list = ClipList()
        list.add(Clip(title: "A", span: TimeSpan(start: 10, end: 40), state: .rejected), sourceDuration: 100)
        let added = list.propose([
            Clip(title: "Same moment", span: TimeSpan(start: 12, end: 38)),
            Clip(title: "Touches the edge", span: TimeSpan(start: 35, end: 70)),
        ], sourceDuration: 100)
        XCTAssertEqual(added.map(\.title), ["Touches the edge"])
        XCTAssertTrue(added.allSatisfy { $0.state == .proposed })
    }

    func testAddClampsAndDropsTinyClips() {
        var list = ClipList()
        XCTAssertNil(list.add(Clip(title: "Tiny", span: TimeSpan(start: 5, end: 5.2)), sourceDuration: 10))
        let clip = list.add(Clip(title: "Over", span: TimeSpan(start: 8, end: 20)), sourceDuration: 10)
        XCTAssertEqual(clip?.end, 10)
    }

    func testTrimKeepsAMinimumLength() {
        var list = ClipList()
        let clip = list.add(Clip(title: "A", span: TimeSpan(start: 10, end: 20)), sourceDuration: 30)!
        list.trim(clip.id, start: 19.9, sourceDuration: 30)
        XCTAssertEqual(list.clip(id: clip.id)?.span, TimeSpan(start: 19, end: 20))
        list.trim(clip.id, end: 40, sourceDuration: 30)
        XCTAssertEqual(list.clip(id: clip.id)?.end, 30)
    }

    func testVisibleShowsAcceptedFirstAndHidesRejected() {
        var list = ClipList()
        list.add(Clip(title: "Low", span: TimeSpan(start: 0, end: 10), score: 0.2, state: .accepted), sourceDuration: 100)
        list.add(Clip(title: "High", span: TimeSpan(start: 20, end: 30), score: 0.9), sourceDuration: 100)
        list.add(Clip(title: "No", span: TimeSpan(start: 40, end: 50), score: 1, state: .rejected), sourceDuration: 100)
        XCTAssertEqual(list.visible.map(\.title), ["Low", "High"])
    }

    func testClipLeavesOutTheEditorsCuts() {
        var edits = EditList(sourceDuration: 100)
        edits.add(Cut(span: TimeSpan(start: 15, end: 18)))
        let clip = Clip(title: "A", span: TimeSpan(start: 10, end: 30))
        XCTAssertEqual(clip.keptSpans(in: edits), [TimeSpan(start: 10, end: 15), TimeSpan(start: 18, end: 30)])
        XCTAssertEqual(clip.duration(in: edits), 17, accuracy: 1e-9)
    }

    func testRoundTripsThroughJSON() throws {
        var list = ClipList()
        list.add(Clip(title: "A", hook: "Here's how.", span: TimeSpan(start: 1, end: 20), score: 0.7,
                      reason: "strong opening", origin: Clip.Origin.agent, format: .square,
                      framing: ClipFraming(mode: .fixed, centerX: 0.3, centerY: 0.5)), sourceDuration: 30)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID()).json")
        try list.write(to: url)
        XCTAssertEqual(try ClipList.read(from: url), list)
        XCTAssertEqual(try ClipList.load(from: url.appendingPathExtension("missing")), ClipList())
    }

    func testClipFileNameIsSafeForFinder() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/Vision One 2026-10-27 at 10.53.12"))
        let clip = Clip(title: "Why: the fastest/easiest way to ship your beta…", span: TimeSpan(start: 0, end: 10))
        XCTAssertEqual(take.clipURL(for: clip).lastPathComponent,
                       "Vision One 2026-10-27 at 10.53.12 - Why the fastesteasiest way to ship (vertical).mp4")
    }
}

final class ClipFrameTests: XCTestCase {
    func testVerticalWindowOnAWideScreen() {
        let rect = ClipFrame.rect(format: .vertical, sourceAspect: 16.0 / 9.0,
                                  framing: ClipFraming(mode: .fixed, centerX: 0.5))
        XCTAssertEqual(rect.width, (9.0 / 16.0) / (16.0 / 9.0), accuracy: 1e-9)
        XCTAssertEqual(rect.height, 1)
        XCTAssertEqual(rect.centerX, 0.5, accuracy: 1e-9)
    }

    func testWindowSlidesBackInsideTheFrame() {
        let rect = ClipFrame.rect(format: .square, sourceAspect: 16.0 / 9.0,
                                  framing: ClipFraming(mode: .fixed, centerX: 0.98))
        XCTAssertEqual(rect.x + rect.width, 1, accuracy: 1e-9)
    }

    func testFitAndSameShapeUseTheWholeFrame() {
        XCTAssertEqual(ClipFrame.rect(format: .vertical, sourceAspect: 1.6, framing: ClipFraming(mode: .fit)), .full)
        XCTAssertEqual(ClipFrame.rect(format: .landscape, sourceAspect: 16.0 / 9.0, framing: .follow), .full)
    }

    func testFollowCentresOnWhereTheCursorSpentTheClip() {
        var log = EventLog(displayWidth: 1000, displayHeight: 500)
        for i in 0..<10 { log.append(InputEvent(kind: .move, t: 10 + Double(i) * 0.1, x: 800, y: 250)) }
        log.append(InputEvent(kind: .move, t: 11.2, x: 50, y: 50)) // one fling
        log.append(InputEvent(kind: .leftDown, t: 50, x: 100, y: 100)) // outside the clip
        let center = ClipFrame.followCenter(events: log, span: TimeSpan(start: 9, end: 20))
        XCTAssertEqual(center.x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
    }

    func testClipSettingsUseTheFormatSize() throws {
        let settings = try ExportPlanner.settings(for: .vertical, sourceFrameRate: 60, duration: 30)
        XCTAssertEqual(settings.width, 1080)
        XCTAssertEqual(settings.height, 1920)
        XCTAssertEqual(settings.frameRate, 30)
        XCTAssertThrowsError(try ExportPlanner.settings(for: .square, sourceFrameRate: 30, duration: 0))
    }
}

final class ClipFinderTests: XCTestCase {
    private var options: ClipFinder.Options {
        var o = ClipFinder.Options()
        o.minDuration = 4
        o.maxDuration = 9
        o.targetDuration = 6
        o.maxClips = 3
        return o
    }

    func testSentencesSplitOnPunctuationAndPauses() {
        let transcript = makeTranscript(["Hello there.", "this has no stop", "Is it working?"], gap: 1.0)
        let finder = ClipFinder()
        let sentences = finder.sentences(transcript: transcript, edits: EditList(sourceDuration: transcript.duration))
        XCTAssertEqual(sentences.map(\.text), ["Hello there.", "this has no stop", "Is it working?"])
    }

    func testCutWordsAreLeftOut() {
        let transcript = makeTranscript(["Um so here we go."])
        var edits = EditList(sourceDuration: transcript.duration)
        let um = transcript.words[0]
        edits.add(Cut(span: TimeSpan(start: um.start, end: um.end)))
        let sentences = ClipFinder().sentences(transcript: transcript, edits: edits)
        XCTAssertEqual(sentences.first?.text, "so here we go.")
    }

    func testCandidatesAreWholeSentencesWithinTheLimits() {
        let transcript = makeTranscript((1...12).map { "Sentence number \($0) is right here." })
        let finder = ClipFinder(options: options)
        let edits = EditList(sourceDuration: transcript.duration)
        let candidates = finder.candidates(transcript: transcript, edits: edits)
        XCTAssertFalse(candidates.isEmpty)
        for c in candidates {
            XCTAssertGreaterThanOrEqual(c.duration, 4)
            XCTAssertLessThanOrEqual(c.duration, 9)
            XCTAssertTrue(c.sentences.last!.endsCleanly)
        }
    }

    func testPicksDontOverlapAndPreferAHook() {
        var lines = (1...10).map { "and then this part \($0) goes on." }
        lines.insert("How do you ship a beta in 10 minutes?", at: 4)
        lines.insert("Here's the trick that works.", at: 5)
        let transcript = makeTranscript(lines)
        let finder = ClipFinder(options: options)
        let clips = finder.clips(transcript: transcript, edits: EditList(sourceDuration: transcript.duration))
        XCTAssertFalse(clips.isEmpty)
        XCTAssertEqual(clips.first?.hook, "How do you ship a beta in 10 minutes?")
        XCTAssertEqual(clips.first?.title, "How do you ship a beta in…")
        XCTAssertEqual(clips.first?.origin, Clip.Origin.auto)
        for (a, b) in zip(clips, clips.dropFirst()) {
            XCTAssertFalse(a.span.overlaps(b.span))
            XCTAssertGreaterThanOrEqual(a.score, b.score)
        }
    }

    func testAvoidsExistingClips() {
        let transcript = makeTranscript((1...12).map { "Here's point \($0) for you." })
        let finder = ClipFinder(options: options)
        let edits = EditList(sourceDuration: transcript.duration)
        let first = finder.clips(transcript: transcript, edits: edits)
        let again = finder.clips(transcript: transcript, edits: edits, existing: first)
        for clip in again {
            XCTAssertFalse(first.contains { $0.span.overlaps(clip.span) })
        }
    }

    func testTitleDropsHesitationsAndTrailingStop() {
        let words = makeTranscript(["Um, ship it today."]).words
        XCTAssertEqual(ClipFinder.title(for: words), "Ship it today")
    }

    func testEmptyTranscriptFindsNothing() {
        let transcript = Transcript(language: "en", engine: "test", duration: 30, segments: [])
        XCTAssertTrue(ClipFinder().clips(transcript: transcript, edits: EditList(sourceDuration: 30)).isEmpty)
    }
}
