import XCTest
@testable import VisionOneKit

final class ProjectBookTests: XCTestCase {
    let a = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-27 10.00.00"))
    let b = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-27 11.00.00"))

    func testStartsWithMyVideos() {
        let book = ProjectBook()
        XCTAssertEqual(book.projects.map(\.name), ["My videos"])
        XCTAssertEqual(book.projectID(for: a), ProjectBook.defaultID)
    }

    func testMoveAndDeleteKeepsTakes() {
        var book = ProjectBook()
        let launch = book.add(named: "  RankRide launch\n")
        XCTAssertEqual(launch.name, "RankRide launch")
        book.move(a, to: launch.id)
        XCTAssertEqual(book.projectID(for: a), launch.id)
        XCTAssertEqual(book.takes(in: launch.id, from: [a, b]), [a])
        XCTAssertEqual(book.takes(in: ProjectBook.defaultID, from: [a, b]), [b])
        book.move(a, to: ProjectBook.defaultID)
        XCTAssertEqual(book.projectID(for: a), ProjectBook.defaultID)
        book.move(b, to: launch.id)
        book.delete(launch.id)
        XCTAssertEqual(book.projectID(for: b), ProjectBook.defaultID)
        book.delete(ProjectBook.defaultID)
        XCTAssertEqual(book.projects.count, 1)
    }

    func testRenameIgnoresBlank() {
        var book = ProjectBook()
        let p = book.add(named: "")
        XCTAssertEqual(p.name, "New project")
        book.rename(p.id, to: "   ")
        XCTAssertEqual(book.project(p.id)?.name, "New project")
        book.rename(p.id, to: "Demos")
        XCTAssertEqual(book.project(p.id)?.name, "Demos")
    }

    func testReorderKeepsDefaultFirst() {
        var book = ProjectBook()
        book.add(named: "One"); book.add(named: "Two"); book.add(named: "Three")
        book.reorder(from: [3], to: 1)
        XCTAssertEqual(book.projects.map(\.name), ["My videos", "Three", "One", "Two"])
        book.reorder(from: [1], to: 4)
        XCTAssertEqual(book.projects.map(\.name), ["My videos", "One", "Two", "Three"])
        book.reorder(from: [0], to: 3)
        XCTAssertEqual(book.projects.first?.name, "My videos")
    }

    func testSavesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("projects.json")
        var book = ProjectBook()
        let p = book.add(named: "Launch")
        book.move(a, to: p.id)
        try book.save(to: url)
        let loaded = ProjectBook.load(from: url)
        XCTAssertEqual(loaded.projectID(for: a), p.id)
        XCTAssertEqual(ProjectBook.load(from: url.appendingPathExtension("missing")).projects.count, 1)
    }
}

final class ComposerTests: XCTestCase {
    let launch = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-27 10.00.00"))
    let intro = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-26 09.00.00"))
    var candidates: [MentionCandidate] {
        [MentionCandidate(take: launch, title: "RankRide launch demo"),
         MentionCandidate(take: intro, title: "Intro für Lee")]
    }

    func testCommandAndMentions() {
        let input = ComposerInput.parse("/clips 3 @rankride-launch-demo make them punchy", candidates: candidates)
        XCTAssertEqual(input.command, .clips)
        XCTAssertEqual(input.mentions, [launch])
        XCTAssertEqual(input.text, "3 make them punchy")
    }

    func testPlainWordsAndUnknownCommand() {
        let input = ComposerInput.parse("/nope make it 60s", candidates: candidates)
        XCTAssertNil(input.command)
        XCTAssertEqual(input.text, "/nope make it 60s")
        XCTAssertTrue(ComposerInput.parse("   ", candidates: candidates).isEmpty)
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
        XCTAssertEqual(ComposerCompletion.suggest(for: "/cl", candidates: candidates), .commands([.clips]))
        XCTAssertEqual(ComposerCompletion.suggest(for: "/c", candidates: candidates), .commands([.cut, .captions, .clips, .copy]))
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

final class TaskThreadTests: XCTestCase {
    let take = Take(folder: URL(fileURLWithPath: "/tmp/takes/2026-10-27 10.00.00"))

    func job(_ agent: AgentKind, _ state: AgentJob.State, at seconds: Double, ask: String? = nil) -> AgentJob {
        var job = AgentJob(agent: agent, title: agent.title, take: take, ask: ask,
                           steps: ["Read", "Pick", "Write"], createdAt: Date(timeIntervalSince1970: seconds))
        job.state = state
        job.updatedAt = Date(timeIntervalSince1970: seconds + 5)
        return job
    }

    func testCellsInOrder() {
        var running = job(.clipper, .running, at: 20, ask: "3 clips")
        running.steps[0].state = .done
        running.steps[1].state = .running
        var review = job(.editor, .needsReview, at: 10, ask: "make it 60s")
        review.receipt = "Cut 21 s across 3 parts."
        review.changes = [.cut(UUID())]
        let cells = TaskThread.cells(for: take, jobs: [running, review], queued: ["add music", " "])
        let kinds = cells.map { $0.id.split(separator: "-").first.map(String.init) ?? "" }
        XCTAssertEqual(kinds, ["take", "ask", "plan", "receipt", "ask", "plan", "status", "queued"])
        guard case let .receipt(_, _, text, canKeep, canUndo, undone) = cells[3] else { return XCTFail() }
        XCTAssertEqual(text, "Cut 21 s across 3 parts.")
        XCTAssertTrue(canKeep && canUndo && !undone)
        guard case let .status(_, line, _) = cells[6] else { return XCTFail() }
        XCTAssertEqual(line, "Clipper · Pick")
        XCTAssertEqual(cells.last, .queued(["add music"]))
    }

    func testFailedAndDone() {
        var failed = job(.sharer, .failed, at: 1)
        failed.error = "No connection."
        var done = job(.editor, .done, at: 2)
        done.receipt = "Nothing more to cut."
        let cells = TaskThread.cells(for: nil, jobs: [failed, done])
        XCTAssertEqual(cells.count, 4)
        guard case let .failed(_, _, message) = cells[1] else { return XCTFail() }
        XCTAssertEqual(message, "No connection.")
        guard case let .receipt(_, _, _, canKeep, canUndo, _) = cells[3] else { return XCTFail() }
        XCTAssertFalse(canKeep || canUndo)
    }

    func testSummaryStateAndSort() {
        let other = Take(folder: URL(fileURLWithPath: "/tmp/takes/b"))
        let idle = TaskSummary(take: other, title: "Old", jobs: [], recordedAt: Date(timeIntervalSince1970: 100))
        let working = TaskSummary(take: take, title: "Now", jobs: [job(.clipper, .running, at: 1)])
        XCTAssertEqual(working.state, .working)
        XCTAssertEqual(idle.state, .idle)
        XCTAssertNil(idle.detail)
        let waiting = TaskSummary(take: Take(folder: URL(fileURLWithPath: "/tmp/c")), title: "Wait",
                                  jobs: [job(.sharer, .needsApproval, at: 0)])
        XCTAssertEqual(waiting.state, .needsYou)
        XCTAssertEqual(TaskSummary.sorted([idle, working, waiting]).map(\.title), ["Wait", "Now", "Old"])
    }

    func testApprovalChoices() {
        XCTAssertEqual(ApprovalChoice.no.label(agent: .sharer), "No, and tell Sharer what to do differently")
        XCTAssertEqual(ApprovalChoice.always.decision, .allowForSession)
        XCTAssertEqual(ApprovalChoice.yes.moved(by: -1), .yes)
        XCTAssertEqual(ApprovalChoice.yes.moved(by: 1), .always)
        XCTAssertEqual(ApprovalChoice.no.moved(by: 1), .no)
    }

    func testElapsedAndBusy() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TaskThread.elapsed(since: start, now: Date(timeIntervalSince1970: 12)), "12s")
        XCTAssertEqual(TaskThread.elapsed(since: start, now: Date(timeIntervalSince1970: 65)), "1m 05s")
        XCTAssertTrue(TaskThread.isBusy([job(.editor, .queued, at: 0)]))
        XCTAssertFalse(TaskThread.isBusy([job(.editor, .needsApproval, at: 0)]))
    }
}
