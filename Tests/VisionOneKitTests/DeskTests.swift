import XCTest
@testable import VisionOneKit

final class DeskTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func makeTake() throws -> Take {
        let take = Take(folder: folder.appendingPathComponent("take", isDirectory: true))
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        var words: [TranscriptWord] = []
        var t = 0.0
        for sentence in ["Welcome to the demo.", "Sorry my cat is here.", "Click export and you're done."] {
            for w in sentence.split(separator: " ") {
                words.append(TranscriptWord(id: words.count, text: String(w), start: t, end: t + 0.9))
                t += 1
            }
        }
        try Transcript(language: "en", engine: "test", duration: t, segments: [TranscriptSegment(words: words)])
            .write(to: take.transcriptURL)
        return take
    }

    let reply: @Sendable (AIRequest) -> String = { request in
        if request.task == .producerScript {
            return #"{"title":"What's new","hook":"Three fixes.","lines":["Faster export","Dark… no, light only"],"cta":"Try it"}"#
        }
        return #"[{"name":"s0","probability":0.9},{"name":"s1","probability":0.05},{"name":"s2","probability":0.95}]"#
    }

    func makeDesk(store: URL? = nil) async -> Desk {
        let board = AgentJobBoard()
        let desk = Desk(board: board, storeURL: store)
        let gate = OutboundGate(approver: board.approver(fallback: FixedApprover(.deny)))
        let ladder = AILadder(providers: [FakeProvider(.chatGPT, rung: .chatGPT, reply: reply)], gate: gate)
        await desk.connect(runner: { AgentRunner(board: board, ladder: ladder) })
        return desk
    }

    func wait(_ desk: Desk, until check: (DeskSnapshot) -> Bool) async throws -> DeskSnapshot {
        for _ in 0..<1000 {
            let snap = await desk.snapshot
            if check(snap) { return snap }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Desk never got there")
        throw CancellationError()
    }

    // MARK: Routing

    func testRouterReadsPlainAsks() {
        guard case let .plan(plan) = AskRouter.route("Tighten the open and make 3 clips for Reels") else { return XCTFail() }
        XCTAssertEqual(plan.steps.map(\.agent), [.editor, .clipper])
        XCTAssertEqual(plan.steps[1].action, .clips(count: 3))

        guard case let .plan(post) = AskRouter.route("Write my Version One launch post") else { return XCTFail() }
        XCTAssertEqual(post.steps.map(\.action), [.share(launch: true)])

        guard case let .plan(copy) = AskRouter.route("/copy make it 60s") else { return XCTFail() }
        XCTAssertTrue(copy.inCopy)
        XCTAssertEqual(copy.steps.first?.action, .edit(ask: "make it 60s"))

        XCTAssertEqual(AskRouter.route("/captions"), .open("captions"))
        guard case let .plan(script) = AskRouter.route("Write a script from the release notes") else { return XCTFail() }
        XCTAssertEqual(script.steps.first?.agent, .producer)
        XCTAssertEqual(SlashCommand.matching("/cl").map(\.name), ["clips"])
    }

    // MARK: Desk

    func testJustDoItRunsAndApprovalLandsInTheThread() async throws {
        let take = try makeTake()
        let desk = await makeDesk()
        let task = await desk.newTask(title: "Launch demo", takes: [take])
        _ = await desk.submit("make it shorter", to: task.id)

        let waiting = try await wait(desk) { $0.task(task.id)?.openApprovals.isEmpty == false }
        let current = waiting.task(task.id)!
        XCTAssertEqual(waiting.status(of: current), .needsYou)
        XCTAssertTrue(waiting.statusLine(of: current).hasPrefix("Needs you · send to"))
        let card = current.openApprovals[0]
        XCTAssertEqual(card.options.count, 3)
        XCTAssertEqual(card.preselected, 0)
        XCTAssertEqual(waiting.needsYou.map(\.id), [task.id])

        await desk.confirm(card.id, in: task.id)
        let done = try await wait(desk) { snap in
            snap.task(task.id)?.cells.contains { if case .receipt = $0.kind { return true } else { return false } } == true
        }
        let finished = done.task(task.id)!
        XCTAssertEqual(done.status(of: finished), .ready)
        XCTAssertEqual(done.statusLine(of: finished), "Cut 5 s across 1 part.")

        try await desk.keepAll(in: task.id)
        _ = try await wait(desk) { $0.status(of: $0.task(task.id)!) == .done }
        XCTAssertEqual(try EditList.read(from: take.editsURL).cuts.map(\.state), [.accepted])
    }

    func testPlanFirstWaitsForTheYes() async throws {
        let take = try makeTake()
        let desk = await makeDesk()
        let task = await desk.newTask(takes: [take], mode: .planFirst)
        _ = await desk.submit("make 2 clips", to: task.id)
        let snap = await desk.snapshot
        let t = snap.task(task.id)!
        XCTAssertNotNil(t.pendingPlan)
        XCTAssertEqual(t.openApprovals.first?.subject, .plan)
        XCTAssertTrue(snap.jobs(for: t).isEmpty)

        await desk.answer(t.openApprovals[0].id, in: task.id, choice: 1, note: nil)
        let after = await desk.snapshot
        XCTAssertTrue(after.task(task.id)!.openApprovals.isEmpty)
        XCTAssertTrue(after.jobs(for: after.task(task.id)!).isEmpty)
    }

    func testAsksWhileBusyAreQueuedThenRun() async throws {
        let take = try makeTake()
        let desk = await makeDesk()
        let task = await desk.newTask(takes: [take])
        _ = await desk.submit("make it shorter", to: task.id)
        _ = await desk.submit("now write the post", to: task.id)
        let queued = await desk.task(task.id)?.queued
        XCTAssertEqual(queued, ["now write the post"])

        _ = try await wait(desk) { $0.task(task.id)?.openApprovals.isEmpty == false }
        await desk.stop(task.id)
        let stopped = try await wait(desk) { snap in
            let jobs = snap.jobs(for: snap.task(task.id)!)
            return !jobs.isEmpty && jobs.allSatisfy { !$0.state.isActive }
        }
        XCTAssertEqual(stopped.task(task.id)?.queued, [])
        XCTAssertEqual(stopped.jobs(for: stopped.task(task.id)!).map(\.state), [.cancelled])
    }

    func testDeskSavesProjectsAndTasks() async throws {
        let url = folder.appendingPathComponent("desk.json")
        let desk = Desk(board: AgentJobBoard(), storeURL: url)
        let project = await desk.newProject("RankRide", sources: [ScriptSourceRef(.github, "rankride/app")])
        let task = await desk.newTask(in: project.id, title: "Driver onboarding")
        await desk.rename(task.id, to: "Driver onboarding v2")

        let again = Desk(board: AgentJobBoard(), storeURL: url)
        let snap = await again.snapshot
        XCTAssertEqual(snap.projects.map(\.name), ["RankRide"])
        XCTAssertEqual(snap.projects[0].initial, "R")
        XCTAssertEqual(snap.tasks(in: snap.projects[0]).map(\.title), ["Driver onboarding v2"])
    }

    // MARK: Project settings

    func testProjectSettingsSaveThroughTheDesk() async throws {
        let url = folder.appendingPathComponent("desk.json")
        let desk = Desk(board: AgentJobBoard(), storeURL: url)
        let project = await desk.newProject("New project")

        var draft = project
        draft.name = "  RankRide  "
        draft.notes = "For drivers in Joburg. Say rand, not dollars.\n\n"
        draft.presetName = "Builder"
        draft.sources = [ScriptSourceRef(.github, "https://github.com/rankride/app.git"),
                         ScriptSourceRef(.github, "RankRide/App"),
                         ScriptSourceRef(.linear, "eng", enabled: false),
                         ScriptSourceRef(.github, "not a repo")]
        let settings = draft
        await desk.updateProject(project.id) { $0.applySettings(settings) }

        let saved = Desk(board: AgentJobBoard(), storeURL: url)
        let loaded = await saved.project(project.id)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.name, "RankRide")
        XCTAssertEqual(reloaded.notes, "For drivers in Joburg. Say rand, not dollars.")
        XCTAssertEqual(reloaded.presetName, "Builder")
        XCTAssertEqual(reloaded.sources, [ScriptSourceRef(.github, "rankride/app"),
                                          ScriptSourceRef(.linear, "ENG", enabled: false)])
        XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, project.createdAt.timeIntervalSince1970, accuracy: 1)

        var blank = reloaded
        blank.name = "   "
        blank.presetName = " "
        var applied = reloaded
        applied.applySettings(blank)
        XCTAssertEqual(applied.name, "RankRide")
        XCTAssertNil(applied.presetName)
    }

    func testSourceRefReadsWhatPeopleType() {
        XCTAssertEqual(DeskProject.sourceRef(.github, from: "rankride/app")?.id, "rankride/app")
        XCTAssertEqual(DeskProject.sourceRef(.github, from: " https://github.com/rankride/app/releases ")?.id, "rankride/app")
        XCTAssertEqual(DeskProject.sourceRef(.github, from: "github.com/rankride/app.git")?.id, "rankride/app")
        XCTAssertNil(DeskProject.sourceRef(.github, from: "rankride"))
        XCTAssertNil(DeskProject.sourceRef(.github, from: "a/b/c"))
        XCTAssertNil(DeskProject.sourceRef(.github, from: "rank ride/app"))
        XCTAssertEqual(DeskProject.sourceRef(.linear, from: "eng")?.id, "ENG")
        XCTAssertEqual(DeskProject.sourceRef(.linear, from: "https://linear.app/rankride/team/ENG/active")?.id, "ENG")
        XCTAssertNil(DeskProject.sourceRef(.linear, from: "linear.app/rankride"))
        XCTAssertNil(DeskProject.sourceRef(.linear, from: "Eng team"))
        XCTAssertNil(DeskProject.sourceRef(.linear, from: ""))
    }

    func testOlderProjectsWithoutSettingsStillLoad() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Weekly updates","createdAt":"2026-10-01T08:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(DeskProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.id, id)
        XCTAssertEqual(project.name, "Weekly updates")
        XCTAssertEqual(project.notes, "")
        XCTAssertEqual(project.sources, [])
        XCTAssertNil(project.presetName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(DeskProject.self, from: encoder.encode(project)), project)
    }

    func testScriptStepRepliesWithTheScript() async throws {
        let desk = await makeDesk()
        let board = await desk.board
        let task = await desk.newTask(ask: "/script")
        let waiting = try await wait(desk) { $0.task(task.id)?.openApprovals.isEmpty == false }
        await desk.confirm(waiting.task(task.id)!.openApprovals[0].id, in: task.id)
        let done = try await wait(desk) { snap in
            snap.task(task.id)?.cells.contains { if case .reply(.producer, _) = $0.kind { return true } else { return false } } == true
        }
        let jobs = await board.jobs
        XCTAssertEqual(jobs.first?.agent, .producer)
        XCTAssertEqual(done.status(of: done.task(task.id)!), .done)
    }

    // MARK: Versions

    func testCopiesAndMakeMainSwapEditLists() throws {
        let take = try makeTake()
        var main = EditList(sourceDuration: 15)
        main.add(Cut(span: TimeSpan(start: 1, end: 2)))
        try main.write(to: take.editsURL)

        var versions = TakeVersions.load(for: take)
        let copy = try versions.makeCopy(in: take)
        XCTAssertEqual(copy.name, "Copy 1")
        var copied = try EditList.read(from: TakeVersions.url(of: copy, in: take))
        copied.add(Cut(span: TimeSpan(start: 5, end: 8)))
        try copied.write(to: TakeVersions.url(of: copy, in: take))

        try versions.makeMain(copy.id, in: take)
        XCTAssertEqual(try EditList.read(from: take.editsURL).cuts.count, 2)
        XCTAssertTrue(versions.version(copy.id)!.isMain)
        XCTAssertEqual(versions.copies.first?.name, "Earlier main cut")
        XCTAssertEqual(try EditList.read(from: TakeVersions.url(of: versions.copies[0], in: take)).cuts.count, 1)

        versions.lock(versions.copies[0].id)
        XCTAssertThrowsError(try versions.remove(versions.copies[0].id, in: take))
        try versions.write(for: take)
        XCTAssertEqual(TakeVersions.load(for: take).versions.map(\.file), versions.versions.map(\.file))
    }

    // MARK: Sources

    func testParsesReleasesAndIssues() throws {
        let gh = ScriptSourceRef(.github, "rankride/app")
        let releases = #"[{"name":"v1.4","tag_name":"v1.4","body":"Faster export","html_url":"https://x","published_at":"2026-10-20T10:00:00Z"},{"name":"","tag_name":"v1.5-rc","draft":true}]"#
        let items = try ScriptSources.parseReleases(Data(releases.utf8), ref: gh)
        XCTAssertEqual(items.map(\.title), ["v1.4"])

        let linear = ScriptSourceRef(.linear, "ENG")
        let issues = #"{"data":{"issues":{"nodes":[{"identifier":"ENG-12","title":"Fix queue count","description":"Off by one","url":"https://l","completedAt":"2026-10-21T09:30:00.000Z"}]}}}"#
        let parsed = try ScriptSources.parseIssues(Data(issues.utf8), ref: linear)
        XCTAssertEqual(parsed.first?.title, "ENG-12 Fix queue count")
        XCTAssertNotNil(parsed.first?.date)

        let request = try ScriptSources.releasesRequest(gh, token: "t", limit: 3)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/rankride/app/releases?per_page=3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertThrowsError(try ScriptSources.releasesRequest(ScriptSourceRef(.github, "nope"), token: nil, limit: 3))
    }
}

extension DeskTests {
    func testImportedSourceTitleReachesTaskAndSurvivesReopening() async throws {
        let source = folder.appendingPathComponent("Launch walkthrough.mp4")
        try Data([0, 1, 2, 3]).write(to: source)
        let take = try VideoImport.copy(source, into: TakeLibrary(folder: folder.appendingPathComponent("library")))
        let store = folder.appendingPathComponent("desk.json")
        let desk = await makeDesk(store: store)
        let task = await desk.taskForRecording(take)
        XCTAssertEqual(task.title, "Launch walkthrough")
        XCTAssertEqual(try Data(contentsOf: take.screenURL), Data([0, 1, 2, 3]))
        await desk.rename(task.id, to: "Final review")
        try take.setTitle("Later library title")
        let reopened = await desk.taskForRecording(take)
        XCTAssertEqual(reopened.id, task.id)
        XCTAssertEqual(reopened.title, "Final review")
        let reloadedDesk = await makeDesk(store: store)
        let reloaded = await reloadedDesk.taskForRecording(take)
        XCTAssertEqual(reloaded.id, task.id)
        XCTAssertEqual(reloaded.title, "Final review")
    }

    func testRecordingFallbackAndExplicitAskTitleRemainAvailable() throws {
        let take = try makeTake()
        XCTAssertEqual(Desk.title(for: nil, takes: [take]), "Recording · \(take.name)")
        try take.setTitle("Imported source title")
        XCTAssertEqual(Desk.title(for: "/cut the opening", takes: [take]), "Cut the opening")
    }
}
