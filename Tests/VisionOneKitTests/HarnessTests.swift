import XCTest
@testable import VisionOneKit

final class ComposerTests: XCTestCase {
    let launch = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-27 10.00.00"))
    let intro = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-26 09.00.00"))
    var candidates: [MentionCandidate] {
        [MentionCandidate(take: launch, title: "RankRide launch demo"),
         MentionCandidate(take: intro, title: "Intro für Lee")]
    }

    func testMentionsComeOut() {
        let input = ComposerInput.parse("/clips 3 @rankride-launch-demo make them punchy", candidates: candidates)
        XCTAssertEqual(input.mentions, [launch])
        XCTAssertEqual(input.text, "/clips 3 make them punchy")
        XCTAssertEqual(ComposerInput.parse("make it 60s", candidates: candidates).mentions, [])
    }

    func testMentionByPrefixAccentsAndFolder() {
        XCTAssertEqual(ComposerInput.parse("@rank", candidates: candidates).mentions, [launch])
        XCTAssertEqual(ComposerInput.parse("@intro-fur-lee", candidates: candidates).mentions, [intro])
        // Ambiguous prefixes stay as words.
        let both = [MentionCandidate(take: launch, title: "Demo one"), MentionCandidate(take: intro, title: "Demo two")]
        let input = ComposerInput.parse("@demo", candidates: both)
        XCTAssertEqual(input.mentions, [])
        XCTAssertEqual(input.text, "@demo")
    }

    func testCompletions() {
        XCTAssertEqual(ComposerCompletion.suggest(for: "/cl", candidates: candidates)?.commandNames, ["clips"])
        XCTAssertEqual(ComposerCompletion.suggest(for: "/c", candidates: candidates)?.commandNames,
                       ["cut", "captions", "clips", "copy"])
        XCTAssertNil(ComposerCompletion.suggest(for: "make /cl", candidates: candidates))
        XCTAssertNil(ComposerCompletion.suggest(for: "/clips ", candidates: candidates))
        XCTAssertEqual(ComposerCompletion.suggest(for: "cut @lau", candidates: candidates),
                       .takes([candidates[0]]))
        XCTAssertEqual(ComposerCompletion.apply("@rankride-launch-demo", to: "cut @lau"), "cut @rankride-launch-demo ")
        XCTAssertEqual(ComposerCompletion.apply("/clips", to: "/cl"), "/clips ")
    }
}

final class PanelLayoutTests: XCTestCase {
    func testShowCloseAndSelect() {
        var layout = PanelLayout.standard
        XCTAssertEqual(layout.selected, .video)
        layout.show(.sound)
        XCTAssertEqual(layout.tabs.last, .sound)
        XCTAssertEqual(layout.selected, .sound)
        layout.close(.sound)
        XCTAssertEqual(layout.selected, .post)
        XCTAssertFalse(layout.addable.contains(.video))
        XCTAssertTrue(layout.addable.contains(.sound))
    }

    func testSplit() {
        var layout = PanelLayout.standard
        layout.toggleSplit()
        XCTAssertEqual(layout.split, .changes)
        layout.show(.changes)
        XCTAssertEqual(layout.selected, .changes)
        XCTAssertEqual(layout.split, .video)
        layout.splitWith(.changes)
        XCTAssertEqual(layout.selected, .video)
        XCTAssertEqual(layout.split, .changes)
        layout.close(.video)
        XCTAssertEqual(layout.selected, .changes)
        XCTAssertNil(layout.split)
        layout.toggleSplit()
        XCTAssertEqual(layout.split, .clips)
        layout.toggleSplit()
        XCTAssertNil(layout.split)
    }

    func testMoveAndClamp() {
        var layout = PanelLayout(tabs: [.video, .video, .post], width: 50, splitFraction: 2)
        XCTAssertEqual(layout.tabs, [.video, .post])
        XCTAssertEqual(layout.width, PanelLayout.minWidth)
        XCTAssertEqual(layout.splitFraction, 0.8)
        layout.move(.post, to: 0)
        XCTAssertEqual(layout.tabs, [.post, .video])
    }

    func testBookRemembersPerTask() {
        var book = PanelLayoutBook()
        var layout = book.layout(for: "a")
        layout.show(.sound)
        book.set(layout, for: "a")
        XCTAssertEqual(book.layout(for: "a").selected, .sound)
        XCTAssertEqual(book.layout(for: "b").selected, .sound, "new tasks start from the last layout")
        let round = PanelLayoutBook.decode(book.encoded())
        XCTAssertEqual(round, book)
        XCTAssertEqual(PanelLayoutBook.decode(nil), PanelLayoutBook())
    }
}

private extension ComposerCompletion {
    var commandNames: [String]? {
        if case let .commands(list) = self { return list.map(\.name) }
        return nil
    }
}
