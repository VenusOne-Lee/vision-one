import XCTest
@testable import VisionOneKit

final class CopiedStyleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("templates-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func profile(format: VideoFormat = .vertical, intro: Double? = nil,
                         captions: CaptionStyle? = .boldPop, purpose: String = "short") -> StyleProfile {
        StyleProfile(
            source: "TikTok", duration: 38, width: 1080, height: 1920, format: format,
            cuts: .init(times: [1.2, 2.4], perMinute: 49, medianShot: 1.2, averageShot: 1.3, pace: .rapid),
            captions: captions.map { .init(style: $0, wordsPerCaption: 2, uppercase: true, placement: .middle,
                                           coverage: 0.9, changesPerMinute: 60) },
            framing: .init(kind: .talkingHead, faceShare: 0.86, faceArea: 0.18, punchInsPerMinute: 5),
            palette: [.init(hex: "#101012", share: 0.6), .init(hex: "#F2EDE4", share: 0.3)],
            brightness: 0.3, intro: intro, outro: 1.5,
            music: .init(share: 0.9, bpm: 120, underVoiceDB: 18), speechShare: 0.95,
            hook: .init(kind: .talksFirst, speechStart: 0.2, firstCut: 1.2),
            energy: .viral, purposeID: purpose, confidence: [:])
    }

    // MARK: - Links

    func testPlatformLinksAreNeverDownloaded() {
        let cases: [(String, StylePlatform)] = [
            ("https://www.youtube.com/watch?v=abc", .youtube), ("https://youtu.be/abc", .youtube),
            ("https://m.youtube.com/shorts/abc", .youtube), ("https://www.tiktok.com/@a/video/1", .tiktok),
            ("https://vm.tiktok.com/xyz", .tiktok), ("https://www.instagram.com/reel/abc/", .instagram),
            ("https://x.com/a/status/1", .x), ("https://twitter.com/a/status/1", .x),
            ("https://www.linkedin.com/posts/abc", .linkedin), ("https://vimeo.com/123", .vimeo),
            ("https://fb.watch/abc", .facebook),
        ]
        for (text, platform) in cases {
            guard case let .platform(found, _)? = StyleSource.classify(text) else {
                return XCTFail("\(text) should be a \(platform.title) link")
            }
            XCTAssertEqual(found, platform, text)
            XCTAssertFalse(StyleSource.classify(text)!.readsDirectly)
        }
    }

    func testLookalikeHostsAreNotPlatforms() {
        guard case .webPage? = StyleSource.classify("https://notyoutube.com/watch") else {
            return XCTFail("a different site that ends in youtube.com isn't YouTube")
        }
    }

    func testFilesAndDirectLinks() {
        XCTAssertEqual(StyleSource.classify("/Users/lee/Movies/launch.mp4"), .file(URL(fileURLWithPath: "/Users/lee/Movies/launch.mp4")))
        XCTAssertEqual(StyleSource.classify(URL(fileURLWithPath: "/tmp/clip.MOV")), .file(URL(fileURLWithPath: "/tmp/clip.MOV")))
        XCTAssertNil(StyleSource.classify(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertEqual(StyleSource.classify("https://cdn.example.com/a/demo.mp4"),
                       .videoLink(URL(string: "https://cdn.example.com/a/demo.mp4")!))
        XCTAssertTrue(StyleSource.classify("https://cdn.example.com/a/demo.mp4")!.readsDirectly)
    }

    func testPastedTextIsTidied() {
        XCTAssertEqual(StyleSource.classify("  <https://vimeo.com/123>\n")?.url.absoluteString, "https://vimeo.com/123")
        XCTAssertEqual(StyleSource.classify("tiktok.com/@a/video/1")?.url.absoluteString, "https://tiktok.com/@a/video/1")
        XCTAssertNil(StyleSource.classify(""))
        XCTAssertNil(StyleSource.classify("hello there"))
        XCTAssertNil(StyleSource.classify("ftp://example.com/a.mp4"))
        XCTAssertNil(StyleSource.classify("javascript:alert(1)"))
    }

    func testLabelNeverCarriesTheLink() {
        let source = StyleSource.classify("https://www.tiktok.com/@a/video/1?is_from_webapp=1&sender=xyz")!
        XCTAssertEqual(source.label, "TikTok")
        XCTAssertFalse(source.explanation.isEmpty)
    }

    // MARK: - Template

    func testDefaultsCopyEverythingButColours() {
        let style = CopiedStyle(profile: profile())
        XCTAssertFalse(style.copies(.colours))
        XCTAssertTrue(style.copies(.cuts))
        XCTAssertNil(style.cardColours)
        XCTAssertEqual(style.energy, .viral)
        XCTAssertEqual(style.zoomsPerMinute, 5)
        XCTAssertEqual(style.keptPause, 0.15)
        XCTAssertEqual(style.wantsMusic, true)
    }

    func testLookFollowsWhatIsCopied() {
        let style = CopiedStyle(profile: profile())
        let look = style.look(id: "fast-short", title: "Fast short")
        XCTAssertEqual(look.id, "fast-short")
        XCTAssertEqual(look.purposeID, "short")
        XCTAssertEqual(look.intro, .off)
        XCTAssertEqual(look.outro, .brand)
        XCTAssertEqual(look.pickedFormats, [.vertical])
        XCTAssertEqual(look.reframe(for: .vertical), .follow)
        XCTAssertEqual(look.captionStyle, .boldPop)
        XCTAssertEqual(look.summary, "Rapid cuts, bold pop captions, talking head, vertical")
    }

    func testUntickedTraitsComeFromThePurpose() {
        let style = CopiedStyle(profile: profile(format: .landscape, intro: 3, purpose: "launch"),
                                copying: [.framing])
        let look = style.look(id: "x", title: "X")
        let launch = TemplateLook.builtIn(id: "launch")!
        XCTAssertEqual(look.formats, launch.formats)
        XCTAssertEqual(look.captionStyle, launch.captionStyle)
        XCTAssertEqual(look.intro, launch.intro)
        XCTAssertEqual(style.energy, Purpose.launch.energy)
        XCTAssertEqual(style.targetSeconds, Purpose.launch.targetSeconds)
        XCTAssertNil(style.zoomsPerMinute)
        XCTAssertNil(style.wantsMusic)
    }

    func testNoCaptionsMeansCaptionsOff() {
        let look = CopiedStyle(profile: profile(captions: nil)).look(id: "a", title: "A")
        XCTAssertNil(look.captionStyle)
    }

    func testTickingColoursHandsThemToTheCards() {
        let style = CopiedStyle(profile: profile(), copying: [.colours])
        XCTAssertEqual(style.cardColours, ["#101012", "#F2EDE4"])
    }

    func testSavesATemplateFolder() throws {
        let style = CopiedStyle(profile: profile())
        let saved = try UserTemplates.save(style, title: "Fast Talking Short!", in: folder)
        XCTAssertEqual(saved.lastPathComponent, "fast-talking-short")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("template.json").path))

        let again = try UserTemplates.save(style, title: "Fast talking short", in: folder)
        XCTAssertEqual(again.lastPathComponent, "fast-talking-short-2")

        let all = UserTemplates.loadAll(in: folder)
        XCTAssertEqual(all.count, 2)
        let first = all.first { $0.look.id == "fast-talking-short" }
        XCTAssertEqual(first?.look.title, "Fast Talking Short!")
        XCTAssertEqual(first?.style?.profile, style.profile)
        XCTAssertEqual(first?.style?.copying, style.copying)
    }

    func testIDsAvoidBuiltInsAndOddCharacters() {
        XCTAssertEqual(UserTemplates.uniqueID(for: "Short", in: folder), "short-2")
        XCTAssertEqual(UserTemplates.uniqueID(for: "  ☆☆  ", in: folder), "style")
        XCTAssertEqual(UserTemplates.uniqueID(for: "Lekker vibe — vol 2", in: folder), "lekker-vibe-vol-2")
    }

    func testEmptyTitleUsesTheSuggestedOne() throws {
        let saved = try UserTemplates.save(CopiedStyle(profile: profile()), title: "  ", in: folder)
        XCTAssertEqual(try TemplateLook.load(from: saved).title, "Rapid talking head short")
    }

    // MARK: - Naming

    func testNamerSendsOnlyNumbers() {
        let request = StyleNamer.request(for: profile())
        XCTAssertEqual(request.task, .styleName)
        XCTAssertFalse(request.input.contains("TikTok"))
        XCTAssertTrue(request.input.contains("Vertical"))
    }

    func testNamerCleansReplies() {
        let name = StyleNamer.clean(.init(title: "  \"Lekker Quick Cuts.\" ", summary: "  "), fallback: "x")
        XCTAssertEqual(name.title, "Lekker Quick Cuts")
        XCTAssertNil(name.summary)
        XCTAssertEqual(StyleNamer.clean(.init(title: "", summary: nil), fallback: "Fallback").title, "Fallback")
    }

    func testNamerFallsBackWithoutAModel() async {
        let ladder = AILadder(providers: [], gate: OutboundGate(approver: FixedApprover(.deny)))
        let name = await StyleNamer(ladder: ladder).name(profile())
        XCTAssertEqual(name.title, "Rapid talking head short")
    }
}
