import XCTest
@testable import VisionOneKit

final class SharePageLookTests: XCTestCase {
    func testEveryPresetHasAReadableButton() {
        for preset in SharePageLook.Preset.allCases {
            let look = SharePageLook(preset)
            XCTAssertTrue(look.allowsAccent(look.accent), preset.title)
            XCTAssertGreaterThanOrEqual(DesignTokens.contrast(look.onAccent, look.accent), 4.5, preset.title)
            XCTAssertGreaterThanOrEqual(DesignTokens.contrast(DesignTokens.text, look.card), 4.5, preset.title)
        }
    }

    func testTallyOrangeIsNeverAnAccent() {
        var look = SharePageLook()
        XCTAssertFalse(look.setAccent(DesignTokens.tally))
        XCTAssertFalse(look.setAccent(0xF2622A))
        XCTAssertEqual(look.accent, DesignTokens.text)
        XCTAssertFalse(SharePageLook.accentChoices.contains(DesignTokens.tally))
    }

    func testGoldCantCarryAButtonButRingRedCan() {
        var look = SharePageLook()
        XCTAssertFalse(look.setAccent(DesignTokens.ringGold))
        XCTAssertTrue(look.setAccent(DesignTokens.ringRed))
        XCTAssertEqual(look.cssVariables["--s-accent"], "#D62B2B")
    }

    func testEveryAccentChoiceWorksOnEveryBackground() {
        for background in SharePageLook.backgroundChoices {
            var look = SharePageLook()
            look.background = background
            for accent in SharePageLook.accentChoices {
                XCTAssertTrue(look.allowsAccent(accent), SharePageLook.css(accent))
            }
        }
    }

    func testCSSCarriesFontCornersAndColours() {
        let css = SharePageLook(.print).cssVariables
        XCTAssertEqual(css["--s-body"], "var(--f-mono)")
        XCTAssertEqual(css["--s-r"], "4px")
        XCTAssertEqual(css["--s-bg"], "#FFFFFF")
        XCTAssertEqual(css.keys.filter { !$0.hasPrefix("--s-") }, [])
    }
}

final class SharePageDocumentTests: XCTestCase {
    private func word(_ id: Int, _ text: String, _ start: Double) -> TranscriptWord {
        TranscriptWord(id: id, text: text, start: start, end: start + 1)
    }

    private var transcript: Transcript {
        Transcript(language: "en", engine: "test", duration: 13, segments: [
            TranscriptSegment(words: [word(0, "Hello", 0), word(1, "there.", 1)]),
            TranscriptSegment(words: [word(2, "Cut", 5), word(3, "me.", 6)]),
            TranscriptSegment(words: [word(4, "Kept", 10), word(5, "end.", 11)]),
        ])
    }

    func testLinesMoveToExportTimeAndSkipCutSentences() {
        let timeline = ExportTimeline(keep: [0..<3, 9..<13], sourceDuration: 13, frameRate: 0)
        let lines = SharePageDocument.lines(from: transcript, timeline: timeline)
        XCTAssertEqual(lines.map(\.text), ["Hello there.", "Kept end."])
        XCTAssertEqual(lines[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(lines[1].start, 4, accuracy: 0.001)
        XCTAssertEqual(lines[1].end, 6, accuracy: 0.01)
    }

    func testTitleAndChaptersComeFromTheSharerDraft() {
        let pack = SharePack(title: "RankRide in a minute", description: "Skip the taxi queue.",
                             chapters: [.init(start: 0, title: "Intro")], posts: [], launch: nil,
                             provider: nil, createdAt: Date())
        let doc = SharePageDocument.make(transcript: transcript, pack: pack, fallbackTitle: "Take 3",
                                         author: "Lee", look: SharePageLook(.purple))
        XCTAssertEqual(doc.title, "RankRide in a minute")
        XCTAssertEqual(doc.description, "Skip the taxi queue.")
        XCTAssertEqual(doc.chapters.map(\.title), ["Intro"])
        XCTAssertEqual(doc.lookName, "Purple")
        XCTAssertTrue(doc.slug.hasPrefix("rankride-in-a-minute-"))
        XCTAssertFalse(doc.isInteractive)
    }

    func testSlugIsLinkSafe() {
        XCTAssertEqual(SharePageDocument.slug(for: "Café — launch: v2!", tail: "ab12"), "cafe-launch-v2-ab12")
        XCTAssertEqual(SharePageDocument.slug(for: "🎬", tail: "x"), "video-x")
        XCTAssertNotEqual(SharePageDocument.slug(for: "Demo"), SharePageDocument.slug(for: "Demo"))
    }
}

final class VideoAnswererTests: XCTestCase {
    private let lines: [SharePageDocument.Line] = [
        .init(start: 0, end: 5, text: "Hi, I'm Lee, and this is RankRide."),
        .init(start: 6, end: 12, text: "You see the price up front, in rand, with no surge at 2am."),
        .init(start: 13, end: 19, text: "Drivers get paid the same day, straight to their bank."),
        .init(start: 20, end: 26, text: "We're live at OR Tambo and Cape Town International now."),
    ]

    func testFindsTheLineThatAnswers() {
        XCTAssertEqual(VideoAnswerer.answer("How much does it cost?", in: lines).first?.start, 6)
        XCTAssertEqual(VideoAnswerer.answer("Where is it live?", in: lines).first?.start, 20)
        XCTAssertEqual(VideoAnswerer.answer("How do drivers get paid?", in: lines).first?.start, 13)
    }

    func testSaysNothingWhenTheVideoDoesnt() {
        XCTAssertEqual(VideoAnswerer.answer("Does it work in Lagos?", in: lines), [])
        XCTAssertEqual(VideoAnswerer.answer("what is the", in: lines), [])
    }
}

final class ViewerInsightsTests: XCTestCase {
    /// 10 visits to a 60 s video: 4 finish, 4 leave after 15 s, 2 after 40 s.
    private var events: [ViewerEvent] {
        var out: [ViewerEvent] = []
        for v in 0..<10 {
            let visit = "v\(v)"
            out.append(ViewerEvent(kind: .view, visit: visit))
            let last: Double = v < 4 ? 60 : (v < 8 ? 15 : 40)
            for at in stride(from: 0.0, through: min(last, 55), by: 5) {
                out.append(ViewerEvent(kind: .progress, visit: visit, at: at))
            }
            if v < 4 { out.append(ViewerEvent(kind: .finish, visit: visit, at: 60)) }
        }
        out.append(ViewerEvent(kind: .reaction, visit: "v0", at: 20, emoji: "🔥"))
        out.append(ViewerEvent(kind: .question, visit: "v1", text: "How much?"))
        return out
    }

    func testCurveCountsHowFarEachVisitGot() {
        let curve = WatchCurve(events: events, duration: 60)
        XCTAssertEqual(curve.views, 10)
        XCTAssertEqual(curve.stillWatching(at: 0), 1)
        XCTAssertEqual(curve.stillWatching(at: 30), 0.6, accuracy: 0.001)
        XCTAssertEqual(curve.stillWatching(at: 50), 0.4, accuracy: 0.001)
        XCTAssertGreaterThan(curve.averageWatched, 25)
        XCTAssertLessThan(curve.averageWatched, 40)
    }

    func testFindsWhereMostPeopleStop() throws {
        let curve = WatchCurve(events: events, duration: 60)
        let drop = try XCTUnwrap(curve.biggestDrop())
        XCTAssertEqual(drop.left, 0.4, accuracy: 0.001)
        XCTAssertTrue((15...20).contains(drop.to), "\(drop.to)")
    }

    func testCoachSuggestsATighterHook() throws {
        let lines: [SharePageDocument.Line] = [
            .init(start: 0, end: 10, text: "Hi, I'm Lee."),
            .init(start: 10, end: 22, text: "Ride apps started in 2009."),
            .init(start: 22, end: 60, text: "RankRide books your spot."),
        ]
        let hint = try XCTUnwrap(ViewerCoachHint.from(curve: WatchCurve(events: events, duration: 60), lines: lines))
        XCTAssertEqual(hint.kind, .hook)
        XCTAssertEqual(hint.line?.text, "Ride apps started in 2009.")
        XCTAssertTrue(hint.headline.hasPrefix("40% of viewers leave by 0:1"), hint.headline)
        XCTAssertTrue(hint.ask.contains("Ride apps started in 2009."))
    }

    func testTooFewViewsSaysNothing() {
        let few = events.filter { ["v0", "v4"].contains($0.visit) }
        XCTAssertNil(WatchCurve(events: few, duration: 60).biggestDrop())
    }

    func testSummary() {
        let summary = ViewerSummary(events: events, duration: 60)
        XCTAssertEqual(summary.views, 10)
        XCTAssertEqual(summary.finished, 4)
        XCTAssertEqual(summary.questions, ["How much?"])
        XCTAssertEqual(summary.reactions.first?.emoji, "🔥")
    }
}

final class ViewerNoteTests: XCTestCase {
    private let take = Take(folder: URL(fileURLWithPath: "/tmp/take"))

    func testANoteBecomesATaskThatNeedsYou() {
        let note = ViewerNote(id: "n1", name: "Thandi", text: "Is the price per person or per car?", at: 33,
                              quote: "You see the price up front.")
        let job = note.job(for: take)
        XCTAssertEqual(job.agent, .editor)
        XCTAssertEqual(job.state, .needsReview)
        XCTAssertTrue(job.state.needsYou)
        XCTAssertEqual(job.takeFolder, take.folder)
        XCTAssertEqual(note.editorAsk, "Thandi said at 0:33, on “You see the price up front.”: Is the price per person or per car?")
    }

    func testBlankNameIsAViewer() {
        XCTAssertEqual(ViewerNote(name: "  ", text: "Skip the history", at: 6).who, "A viewer")
    }

    func testMergeKeepsDoneAndSkipsRepeats() {
        var inbox = ViewerInbox()
        let note = ViewerNote(id: "n1", text: "Faster", at: 6)
        let event = ViewerEvent(kind: .view, visit: "v1", time: Date(timeIntervalSince1970: 10))
        inbox.merge(notes: [note], events: [event])
        inbox.markDone("n1")
        inbox.merge(notes: [note, ViewerNote(id: "n2", text: "Louder", at: 9)], events: [event])
        XCTAssertEqual(inbox.notes.count, 2)
        XCTAssertEqual(inbox.events.count, 1)
        XCTAssertEqual(inbox.openNotes.map(\.id), ["n2"])
    }
}

final class ShareLinkStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testNoLinkUntilPublished() throws {
        let take = Take(folder: folder)
        XCTAssertNil(ShareLinkStore.link(for: take))

        var record = SharePageRecord(slug: "demo-ab12", host: .cloudflare,
                                     url: URL(string: "https://lee.pages.dev/v/demo-ab12"))
        try ShareLinkStore.save(record, for: take)
        XCTAssertNil(ShareLinkStore.link(for: take), "saved but not published yet")

        record.publishedAt = Date()
        try ShareLinkStore.save(record, for: take)
        XCTAssertEqual(ShareLinkStore.link(for: take)?.absoluteString, "https://lee.pages.dev/v/demo-ab12")
        XCTAssertEqual(ShareLinkStore.record(for: take)?.look, SharePageLook())

        try ShareLinkStore.remove(for: take)
        XCTAssertNil(ShareLinkStore.link(for: take))
    }

    func testAStaticFolderHasNoLink() throws {
        let take = Take(folder: folder)
        try ShareLinkStore.save(SharePageRecord(slug: "demo", publishedAt: Date()), for: take)
        XCTAssertNil(ShareLinkStore.link(for: take))
    }
}

final class SharePageBundleTests: XCTestCase {
    private func doc(title: String = "Demo") -> SharePageDocument {
        SharePageDocument(slug: "demo-ab12", title: title, author: "Lee", duration: 10,
                          lines: [.init(start: 0, end: 2, text: "Hi </script><script>alert(1)</script>")])
    }

    func testTemplateShipsWithTheKit() throws {
        let template = try SharePageBundle.template()
        XCTAssertTrue(template.contains(SharePageBundle.placeholder))
        XCTAssertFalse(template.contains("fonts.googleapis.com"), "the page loads nothing from other sites")
    }

    func testDataCantCloseTheScriptTag() throws {
        let html = try SharePageBundle.html(for: doc(), template: "<script>\(SharePageBundle.placeholder)</script>")
        XCTAssertFalse(html.contains("</script><script>"))
        XCTAssertTrue(html.contains("\\u003c/script\\u003e"))
        let json = html.dropFirst("<script>".count).dropLast("</script>".count)
        let decoded = try JSONDecoder().decode(SharePageDocument.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, doc())
    }

    func testWritesTheFolder() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let video = base.appendingPathComponent("take.mp4")
        try Data([0, 1, 2]).write(to: video)
        let out = base.appendingPathComponent("page")

        let index = try SharePageBundle.write(doc(), video: video, captions: "WEBVTT\n", to: out,
                                              template: "<html>\(SharePageBundle.placeholder)</html>")
        XCTAssertEqual(index.lastPathComponent, "index.html")
        for name in ["index.html", "page.json", "video.mp4", "captions.vtt"] {
            XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(try SharePageDocument.read(from: out.appendingPathComponent("page.json")).captions, "captions.vtt")

        XCTAssertThrowsError(try SharePageBundle.write(doc(), video: base.appendingPathComponent("nope.mp4"),
                                                       to: out, template: ""))
    }
}
