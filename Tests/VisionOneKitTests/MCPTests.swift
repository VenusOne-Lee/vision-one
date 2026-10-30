import XCTest
@testable import VisionOneKit

/// Stands in for the app: answers approval cards with what the test says
/// and counts how often it was asked.
actor FakeMCPHost: VisionOneMCPHost {
    var answer: MCPAnswer
    private(set) var questions: [MCPQuestion] = []
    private(set) var shared: [(URL, String?, ShareTarget)] = []
    private(set) var recording = false
    let library: TakeLibrary
    let board: AgentJobBoard
    let reply: @Sendable (AIRequest) -> String

    init(answer: MCPAnswer, library: TakeLibrary, board: AgentJobBoard,
         reply: @escaping @Sendable (AIRequest) -> String = { _ in "[]" }) {
        self.answer = answer
        self.library = library
        self.board = board
        self.reply = reply
    }

    func setAnswer(_ answer: MCPAnswer) { self.answer = answer }

    /// False stands in for the main window being in front: the floating
    /// card stays away and the task's card is the only place to answer.
    var card = true
    func setCard(_ card: Bool) { self.card = card }
    func showsCard(for question: MCPQuestion) async -> Bool { card }

    func ask(_ question: MCPQuestion) async -> MCPAnswer {
        questions.append(question)
        return answer
    }

    func dismiss(_ questionID: UUID) async {}
    func connected(_ client: MCPClient) async {}
    func isRecording() async -> Bool { recording }

    func startRecording() async throws -> Take {
        recording = true
        let take = try library.newTake()
        FileManager.default.createFile(atPath: take.screenURL.path, contents: Data())
        return take
    }

    private(set) var agentStarts: [(agent: String, task: String?, app: String?)] = []
    private(set) var agentSteps: [String] = []

    func startAgentRecording(agent: String, task: String?, app: String?) async throws -> Take {
        agentStarts.append((agent, task, app))
        return try await startRecording()
    }

    func logAgentStep(_ text: String, x: Double?, y: Double?) async -> Bool {
        guard recording, !agentStarts.isEmpty else { return false }
        agentSteps.append(text)
        return true
    }

    func stopRecording() async throws -> Take {
        recording = false
        guard let take = library.takes().first else { throw MCPHostError("No take") }
        return take
    }

    func runner() async -> AgentRunner {
        let gate = OutboundGate(approver: FixedApprover(.allowOnce))
        let provider = FakeProvider(.chatGPT, rung: .chatGPT, reply: reply)
        return AgentRunner(board: board, ladder: AILadder(providers: [provider], gate: gate))
    }

    func plan(for take: Take) async -> TakePlan { TakePlan(purpose: .demo) }
    func brief(for plan: TakePlan) async -> AgentBrief { plan.purpose.brief() }

    func export(_ take: Take, preset: ExportPreset) async throws -> URL {
        let url = take.exportURL(for: preset)
        FileManager.default.createFile(atPath: url.path, contents: Data("mp4".utf8))
        return url
    }

    func share(_ file: URL, text: String?, to target: ShareTarget) async throws {
        shared.append((file, text, target))
    }

    func demos() async -> [DemoFile] {
        let demo = DemoScript(name: "Driver sign-up", app: DemoApp(bundleID: "com.apple.Safari", name: "Safari"),
                              steps: [DemoStep(.click), DemoStep(.click)])
        return [DemoFile(url: URL(fileURLWithPath: "/tmp/driver-sign-up.json"), demo: demo)]
    }

    func rerecordDemo(_ name: String, release: String?, requestedBy: String) async -> UUID? {
        guard name.caseInsensitiveCompare("driver sign-up") == .orderedSame else { return nil }
        var job = AgentJob(agent: .autopilot, title: "Re-record “Driver sign-up”", steps: ["Click"])
        job.requestedBy = requestedBy
        _ = await board.add(job)
        await board.finish(job.id, receipt: "Recorded “Driver sign-up” for \(release ?? "now").", changes: [])
        return job.id
    }
}

final class MCPTests: XCTestCase {
    var folder: URL!
    var library: TakeLibrary!
    let claude = MCPClient(name: "claude-code", version: "2.1")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        library = TakeLibrary(folder: folder)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A take saying "Welcome to the demo. Um sorry my cat is here. Click export and you're done."
    @discardableResult
    func makeTake(at date: Date = Date(timeIntervalSince1970: 1_800_000_000), title: String? = nil) throws -> Take {
        let take = try library.newTake(at: date)
        FileManager.default.createFile(atPath: take.screenURL.path, contents: Data())
        var words: [TranscriptWord] = []
        var t = 0.0
        for sentence in ["Welcome to the demo.", "Um sorry my cat is here.", "Click export and you're done."] {
            for w in sentence.split(separator: " ") {
                words.append(TranscriptWord(id: words.count, text: String(w), start: t, end: t + 0.9))
                t += 1
            }
        }
        let transcript = Transcript(language: "en", engine: "test", duration: t, segments: [TranscriptSegment(words: words)])
        try transcript.write(to: take.transcriptURL)
        if let title { try take.setTitle(title) }
        return take
    }

    func server(answer: MCPAnswer = MCPAnswer(.allowOnce),
                reply: @escaping @Sendable (AIRequest) -> String = { _ in "[]" }) -> (VisionOneMCP, FakeMCPHost) {
        let board = AgentJobBoard()
        let host = FakeMCPHost(answer: answer, library: library, board: board, reply: reply)
        return (VisionOneMCP(library: library, board: board, host: host, patience: 5), host)
    }

    func call(_ mcp: VisionOneMCP, _ tool: String, _ args: [String: JSONValue] = [:]) async -> MCPToolResult {
        await mcp.call(tool, arguments: args, client: claude)
    }

    // MARK: JSON

    func testJSONRoundTripKeepsWholeNumbersWhole() throws {
        let value: JSONValue = ["id": 1, "ratio": 0.5, "name": "take", "ok": true, "none": nil, "list": [1, "two"]]
        let line = String(decoding: value.encodedLine(), as: UTF8.self)
        XCTAssertTrue(line.contains("\"id\":1"))
        XCTAssertFalse(line.contains("1.0"))
        XCTAssertFalse(line.contains("\n"))
        let back = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(back, value)
        XCTAssertEqual(back["ok"]?.boolValue, true)
        XCTAssertEqual(back["id"]?.intValue, 1)
    }

    #if canImport(Darwin)
    func testDevBuildsUseTheirOwnSocket() {
        XCTAssertEqual(MCPSocketPath.fileName(bundleID: "za.co.versionone.visionone"), "mcp.sock")
        XCTAssertEqual(MCPSocketPath.fileName(bundleID: "za.co.versionone.visionone.dev"), "mcp-dev.sock")
        XCTAssertEqual(MCPSocketPath.fileName(bundleID: "za.co.versionone.visionone.verification"), "mcp-verification.sock")
        XCTAssertEqual(MCPSocketPath.fileName(bundleID: nil), "mcp.sock")
    }
    #endif

    func testClientNames() {
        XCTAssertEqual(MCPClient(name: "claude-code").displayName, "Claude Code")
        XCTAssertEqual(MCPClient(name: "codex-mcp-client").displayName, "Codex")
        XCTAssertEqual(MCPClient(name: "cursor-vscode").displayName, "Cursor")
        XCTAssertEqual(MCPClient(name: "my-agent").displayName, "My Agent")
        XCTAssertEqual(MCPClient(name: "x", title: "Zed Agent").displayName, "Zed Agent")
        XCTAssertEqual(MCPClient.unknown.displayName, "An agent")
    }

    // MARK: Protocol

    func send(_ session: MCPSession, _ message: JSONValue) async throws -> JSONValue? {
        guard let reply = await session.handle(message.encodedLine()) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: reply)
    }

    func testInitializeAgreesOnAVersionAndNamesTheClient() async throws {
        let session = MCPSession(server: server().0)
        let reply = try await send(session, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                       "clientInfo": ["name": "claude-code", "version": "2.1.0"]],
        ])
        XCTAssertEqual(reply?["id"], 1)
        XCTAssertEqual(reply?["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(reply?["result"]?["serverInfo"]?["name"]?.stringValue, "vision-one")
        XCTAssertNotNil(reply?["result"]?["capabilities"]?["tools"])
        let client = await session.client
        XCTAssertEqual(client.displayName, "Claude Code")

        let newer = MCPSession(server: server().0)
        let fallback = try await send(newer, ["jsonrpc": "2.0", "id": "a", "method": "initialize",
                                              "params": ["protocolVersion": "2099-01-01"]])
        XCTAssertEqual(fallback?["result"]?["protocolVersion"]?.stringValue, MCPSession.protocolVersions[0])
    }

    func testNotificationsGetNoReplyAndUnknownMethodsAnError() async throws {
        let session = MCPSession(server: server().0)
        let none = try await send(session, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(none)
        let unknown = try await send(session, ["jsonrpc": "2.0", "id": 7, "method": "sampling/whatever"])
        XCTAssertEqual(unknown?["error"]?["code"]?.intValue, -32601)
        let bad = await session.handle(Data("{not json".utf8))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(bad))
        XCTAssertEqual(parsed["error"]?["code"]?.intValue, -32700)
        let ping = try await send(session, ["jsonrpc": "2.0", "id": 8, "method": "ping"])
        XCTAssertEqual(ping?["result"], .object([:]))
    }

    func testToolListIsWellFormed() async throws {
        let session = MCPSession(server: server().0)
        let reply = try await send(session, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap(reply?["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names).count, names.count, "tool names are unique")
        XCTAssertEqual(names.count, VisionOneMCP.tools.count)
        for tool in tools {
            let name = tool["name"]?.stringValue ?? ""
            XCTAssertNotNil(name.range(of: #"^[a-z_]{1,64}$"#, options: .regularExpression), name)
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object", name)
            for required in tool["inputSchema"]?["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(tool["inputSchema"]?["properties"]?[required.stringValue ?? ""], "\(name) requires a known field")
            }
        }
        let share = tools.first { $0["name"]?.stringValue == "share_video" }
        XCTAssertEqual(share?["annotations"]?["openWorldHint"]?.boolValue, true)
        let list = tools.first { $0["name"]?.stringValue == "list_takes" }
        XCTAssertEqual(list?["annotations"]?["readOnlyHint"]?.boolValue, true)
    }

    func testCallingAnUnknownToolIsAProtocolErrorButBadArgumentsAreToolErrors() async throws {
        try makeTake()
        let session = MCPSession(server: server().0)
        let unknown = try await send(session, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                               "params": ["name": "delete_everything"]])
        XCTAssertEqual(unknown?["error"]?["code"]?.intValue, -32602)
        let bad = try await send(session, ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                           "params": ["name": "wait_for_task", "arguments": ["task_id": "nope"]]])
        XCTAssertEqual(bad?["result"]?["isError"]?.boolValue, true)
        XCTAssertNotNil(bad?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
    }

    // MARK: Reading

    func testListAndFindTakes() async throws {
        try makeTake(at: Date(timeIntervalSince1970: 1_800_000_000), title: "Signup demo")
        try makeTake(at: Date(timeIntervalSince1970: 1_800_000_100), title: "Pricing page")
        let (mcp, _) = server()

        let all = await call(mcp, "list_takes")
        XCTAssertEqual(all.data?["takes"]?.arrayValue?.count, 2)
        XCTAssertEqual(all.data?["takes"]?.arrayValue?.first?["title"]?.stringValue, "Pricing page")

        let found = await call(mcp, "list_takes", ["search": "cat"])
        XCTAssertEqual(found.data?["takes"]?.arrayValue?.count, 2)

        XCTAssertEqual(try mcp.resolveTake(["take": "signup demo"]).customTitle(), "Signup demo")
        XCTAssertEqual(try mcp.resolveTake(["take": "latest"]).customTitle(), "Pricing page")
        XCTAssertEqual(try mcp.resolveTake([:]).customTitle(), "Pricing page")
        XCTAssertThrowsError(try mcp.resolveTake(["take": "nothing like it"]))

        let take = await call(mcp, "get_take", ["take": "Signup demo"])
        XCTAssertFalse(take.isError)
        XCTAssertEqual(take.data?["transcript"]?.stringValue, "ready")
        XCTAssertEqual(take.data?["seconds"]?.doubleValue, 15)
    }

    func testTranscriptMarksCutsAndProposals() async throws {
        let take = try makeTake()
        var edits = EditList(sourceDuration: 15)
        _ = edits.add(Cut(span: TimeSpan(start: 4, end: 5), state: .accepted))   // "Um"
        _ = edits.propose([Cut(span: TimeSpan(start: 5, end: 6))])               // "sorry"
        try edits.write(to: take.editsURL)
        let (mcp, _) = server()

        let marked = await call(mcp, "read_transcript")
        XCTAssertTrue(marked.text.contains("~~Um~~"))
        XCTAssertTrue(marked.text.contains("[sorry]"))
        XCTAssertTrue(marked.text.contains("0:00  Welcome"))

        let kept = await call(mcp, "read_transcript", ["kept_only": true])
        XCTAssertFalse(kept.text.contains("Um"))
        XCTAssertTrue(kept.text.contains("sorry"))
        XCTAssertFalse(kept.text.contains("[sorry]"))
    }

    // MARK: Editing

    func testCutPartProposesACutOnATaskMarkedWithTheAgent() async throws {
        let take = try makeTake()
        let (mcp, _) = server()
        let result = await call(mcp, "cut_part", ["quote": "sorry, my CAT"])
        XCTAssertFalse(result.isError, result.text)
        let list = try EditList.read(from: take.editsURL)
        XCTAssertEqual(list.cuts.count, 1)
        XCTAssertEqual(list.cuts.first?.state, .proposed)
        XCTAssertEqual(list.cuts.first?.start, 5)
        XCTAssertEqual(list.cuts.first?.end, 7.9)
        let job = await mcp.board.jobs.first
        XCTAssertEqual(job?.requestedBy, "Claude Code")
        XCTAssertEqual(job?.state, .needsReview)
        XCTAssertEqual(result.data?["task_id"]?.stringValue, job?.id.uuidString)

        let again = await call(mcp, "cut_part", ["quote": "sorry my cat"])
        XCTAssertTrue(again.isError)
        let missing = await call(mcp, "cut_part", ["quote": "not said at all"])
        XCTAssertTrue(missing.isError)
    }

    func testCutPartDryRunChangesNothing() async throws {
        let take = try makeTake()
        let (mcp, _) = server()
        let result = await call(mcp, "cut_part", ["quote": "sorry my cat", "plan": true])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Dry run"), result.text)
        XCTAssertEqual(result.data?["length_before"]?.doubleValue, 15)
        XCTAssertEqual(try XCTUnwrap(result.data?["length_after"]?.doubleValue), 12.1, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.editsURL.path))
        let jobs = await mcp.board.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testTimelineNamesRowsAndWhatChangedSeesTheUsersEdits() async throws {
        let take = try makeTake()
        let (mcp, _) = server()
        let first = await call(mcp, "what_changed")
        XCTAssertFalse(first.isError, first.text)
        XCTAssertEqual(first.data?["first_look"]?.boolValue, true)

        _ = await call(mcp, "cut_part", ["quote": "sorry my cat"])
        let timeline = await call(mcp, "get_timeline")
        XCTAssertFalse(timeline.isError, timeline.text)
        XCTAssertTrue(timeline.text.contains("c1"), timeline.text)
        XCTAssertEqual(timeline.data?["rows"]?.arrayValue?.first?["state"]?.stringValue, "proposed")

        let quiet = await call(mcp, "what_changed")
        XCTAssertEqual(quiet.data?["changes"]?.arrayValue?.count, 0, quiet.text)

        // The user keeps the cut and adds a zoom in the editor.
        var list = try EditList.read(from: take.editsURL)
        list.acceptAllProposed()
        try list.write(to: take.editsURL)
        try ZoomList(zooms: [Zoom(span: TimeSpan(start: 10, end: 12), scale: 2, centerX: 0.5, centerY: 0.5)])
            .write(to: take.zoomsURL)

        let changed = await call(mcp, "what_changed")
        let lines = try XCTUnwrap(changed.data?["changes"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(lines.count, 2, changed.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Kept cut c1") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Added zoom z1") }, "\(lines)")

        // Seen now, so the next look is quiet again.
        let after = await call(mcp, "what_changed")
        XCTAssertEqual(after.data?["changes"]?.arrayValue?.count, 0, after.text)
    }

    func testKeepAsksAndAllowUntilQuitStopsAsking() async throws {
        let take = try makeTake()
        let (mcp, host) = server(answer: MCPAnswer(.allowForSession))
        let first = await call(mcp, "cut_part", ["quote": "Welcome"])
        let firstID = try XCTUnwrap(first.data?["task_id"])
        let kept = await call(mcp, "keep_changes", ["task_id": firstID])
        XCTAssertFalse(kept.isError, kept.text)
        XCTAssertEqual(try EditList.read(from: take.editsURL).cuts.first?.state, .accepted)
        let asked = await host.questions.count
        XCTAssertEqual(asked, 1)

        let second = await call(mcp, "cut_part", ["quote": "Click export"])
        let secondID = try XCTUnwrap(second.data?["task_id"])
        _ = await call(mcp, "keep_changes", ["task_id": secondID])
        let askedAgain = await host.questions.count
        XCTAssertEqual(askedAgain, 1, "allowed until quit")
    }

    func testNoComesBackWithTheUsersNote() async throws {
        let take = try makeTake()
        let (mcp, _) = server(answer: MCPAnswer(.deny, note: "Keep the welcome line"))
        let cut = await call(mcp, "cut_part", ["quote": "Welcome"])
        let cutID = try XCTUnwrap(cut.data?["task_id"])
        let refused = await call(mcp, "keep_changes", ["task_id": cutID])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Keep the welcome line"))
        XCTAssertEqual(try EditList.read(from: take.editsURL).cuts.first?.state, .proposed)
    }

    func testUndoTakesTheCutOut() async throws {
        let take = try makeTake()
        let (mcp, _) = server()
        let cut = await call(mcp, "cut_part", ["start": 4, "end": 5])
        let cutID = try XCTUnwrap(cut.data?["task_id"])
        let undone = await call(mcp, "undo_changes", ["task_id": cutID])
        XCTAssertFalse(undone.isError, undone.text)
        XCTAssertTrue(try EditList.read(from: take.editsURL).cuts.isEmpty)
    }

    func testCleanUpProposesTheFiller() async throws {
        let take = try makeTake()
        let (mcp, _) = server()
        let result = await call(mcp, "clean_up")
        XCTAssertFalse(result.isError, result.text)
        let cuts = try EditList.read(from: take.editsURL).cuts
        XCTAssertTrue(cuts.allSatisfy { $0.state == .proposed })
        XCTAssertTrue(cuts.contains { $0.span.contains(4.5) }, "the um is proposed")
    }

    func testCutToLengthRunsTheEditorAsATaskWithTheAgentsID() async throws {
        try makeTake()
        let reply: @Sendable (AIRequest) -> String = { _ in
            #"[{"name":"s0","probability":0.9},{"name":"s1","probability":0.05},{"name":"s2","probability":0.95}]"#
        }
        let (mcp, _) = server(reply: reply)
        let result = await call(mcp, "cut_to_length", ["seconds": 10])
        XCTAssertFalse(result.isError, result.text)
        let job = await mcp.board.jobs.first
        XCTAssertEqual(job?.agent, .editor)
        XCTAssertEqual(job?.requestedBy, "Claude Code")
        XCTAssertEqual(result.data?["task_id"]?.stringValue, job?.id.uuidString)

        let missing = await call(mcp, "cut_to_length")
        XCTAssertTrue(missing.isError)
    }

    func testCallsLandAsDeskTasksMarkedWithTheAgent() async throws {
        let take = try makeTake()
        let board = AgentJobBoard()
        let desk = Desk(board: board)
        let host = FakeMCPHost(answer: MCPAnswer(.allowOnce), library: library, board: board)
        let mcp = VisionOneMCP(library: library, board: board, desk: desk, host: host, patience: 5)
        let result = await call(mcp, "cut_part", ["quote": "Welcome"])
        XCTAssertFalse(result.isError, result.text)
        let tasks = await desk.tasks
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.requestedBy, "Claude Code")
        XCTAssertEqual(tasks.first?.takeFolders.count, 1)
        XCTAssertTrue(VisionOneMCP.same(tasks.first?.takeFolders.first, take.folder))
        XCTAssertEqual(tasks.first?.jobIDs.count, 1)

        _ = await call(mcp, "clean_up")
        let after = await desk.tasks
        XCTAssertEqual(after.count, 1, "same take, same task")
        XCTAssertEqual(after.first?.jobIDs.count, 2)
    }

    func testWithTheWindowInFrontTheTaskCardIsTheOnlyAsk() async throws {
        let board = AgentJobBoard()
        let desk = Desk(board: board)
        let host = FakeMCPHost(answer: MCPAnswer(.allowOnce), library: library, board: board)
        await host.setCard(false)
        await desk.connect(runner: { await host.runner() })
        let mcp = VisionOneMCP(library: library, board: board, desk: desk, host: host, patience: 5)
        let client = claude
        let recording = Task { await mcp.call("start_recording", arguments: ["for": "demo"], client: client) }

        var found: (task: UUID, card: ApprovalCard)?
        for _ in 0..<500 {
            if let task = await desk.tasks.first, let card = task.openApprovals.first {
                found = (task.id, card)
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let (taskID, card) = try XCTUnwrap(found)
        XCTAssertEqual(card.question, "Record your screen for Claude Code?")
        let snapshot = await desk.snapshot
        let waiting = try XCTUnwrap(snapshot.task(taskID))
        XCTAssertEqual(snapshot.statusLine(of: waiting), "Needs you · Claude Code is asking")

        let no = try XCTUnwrap(card.options.firstIndex { $0.effect == .deny })
        await desk.answer(card.id, in: taskID, choice: no, note: "record the browser window")
        let result = await recording.value
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("record the browser window"), result.text)
        let asked = await host.questions
        XCTAssertTrue(asked.isEmpty, "the floating card never showed")
        let live = await host.isRecording()
        XCTAssertFalse(live)
        let task = await desk.task(taskID)
        XCTAssertEqual(task?.queued.count, 0)
        XCTAssertFalse(task?.cells.contains { if case .ask = $0.kind { return true } else { return false } } ?? true,
                       "the note goes to Claude Code, not to Vision One's agents")
    }

    // MARK: Autopilot demos

    func testListsAndRerecordsDemos() async throws {
        let (mcp, _) = server()
        let listed = await call(mcp, "list_demos")
        XCTAssertFalse(listed.isError, listed.text)
        XCTAssertEqual(listed.data?["demos"]?.arrayValue?.first?["name"]?.stringValue, "Driver sign-up")
        XCTAssertEqual(listed.data?["demos"]?.arrayValue?.first?["steps"]?.intValue, 2)
        let none = await call(mcp, "list_demos", ["search": "checkout"])
        XCTAssertEqual(none.data?["demos"]?.arrayValue?.count, 0)

        let missing = await call(mcp, "rerecord_demo", ["demo": "Checkout"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("Driver sign-up"), missing.text)

        let run = await call(mcp, "rerecord_demo", ["demo": "Driver sign-up", "release": "v1.4.0"])
        XCTAssertFalse(run.isError, run.text)
        let job = await mcp.board.jobs.first
        XCTAssertEqual(run.data?["task_id"]?.stringValue, job?.id.uuidString)
        XCTAssertEqual(job?.requestedBy, "Claude Code")
        XCTAssertTrue(run.text.contains("v1.4.0"), run.text)
    }

    // MARK: Recording, export, share

    func testRecordingAsksFirstAndANoStopsIt() async throws {
        let (mcp, host) = server(answer: .no)
        let refused = await call(mcp, "start_recording", ["for": "demo", "title": "Signup"])
        XCTAssertTrue(refused.isError)
        let live = await host.isRecording()
        XCTAssertFalse(live)
        let job = await mcp.board.jobs.first
        XCTAssertEqual(job?.state, .cancelled)
        let question = await host.questions.first
        XCTAssertEqual(question?.action, .record)
        XCTAssertEqual(question?.title, "Record your screen for Claude Code?")

        let unknown = await call(mcp, "start_recording", ["for": "wedding"])
        XCTAssertTrue(unknown.isError)
    }

    func testAgentRecordingAsksLogsStepsAndProposesWaits() async throws {
        let (mcp, host) = server()
        let early = await call(mcp, "log_step", ["say": "Open the page"])
        XCTAssertTrue(early.isError, "no agent recording yet")

        let started = await call(mcp, "start_agent_recording", ["task": "Sign up on staging", "app": "Safari"])
        XCTAssertFalse(started.isError, started.text)
        let question = await host.questions.last
        XCTAssertEqual(question?.action, .record)
        XCTAssertEqual(question?.title, "Record Claude Code using your Mac?")
        XCTAssertTrue(question?.details.contains { $0.label == "Records" && $0.value == "The Safari window" } == true)
        let starts = await host.agentStarts
        XCTAssertEqual(starts.first?.agent, "Claude Code")
        XCTAssertEqual(starts.first?.app, "Safari")
        let take = try XCTUnwrap(library.takes().first)
        XCTAssertEqual(take.customTitle(), "Sign up on staging")

        let empty = await call(mcp, "log_step", ["say": "  "])
        XCTAssertTrue(empty.isError)
        let logged = await call(mcp, "log_step", ["say": "Open the signup page"])
        XCTAssertFalse(logged.isError, logged.text)
        let steps = await host.agentSteps
        XCTAssertEqual(steps, ["Open the signup page"])

        // What the app writes at stop: a click, 30 s of thinking, a click.
        try AgentActionLog(agent: "Claude Code", actions: [
            AgentAction(kind: .click, t: 2, x: 10, y: 10),
            AgentAction(kind: .click, t: 32, x: 20, y: 20),
        ]).write(for: take)
        try Transcript(language: "en", engine: "test", duration: 40, segments: []).write(to: take.transcriptURL)
        let stopped = await call(mcp, "stop_recording")
        XCTAssertFalse(stopped.isError, stopped.text)
        XCTAssertTrue(stopped.text.contains("2 actions"), stopped.text)
        XCTAssertTrue(stopped.text.contains("waiting"), stopped.text)
        let edits = try EditList.read(from: take.editsURL)
        let waits = edits.cuts.filter { $0.reason == Cut.Reason.waiting }
        XCTAssertEqual(waits.count, 2, "the think in the middle and the tail after the last click")
        XCTAssertTrue(waits.allSatisfy { $0.state == .proposed })
        let job = await mcp.board.jobs.first { $0.takeFolder != nil }
        XCTAssertEqual(job?.state, .needsReview, "the proposed skips wait for the user")
        XCTAssertEqual(job?.changes.count, 2, "keep_changes on the task keeps the skips")
    }

    func testAgentRecordingNoStopsIt() async throws {
        let (mcp, host) = server(answer: .no)
        let refused = await call(mcp, "start_agent_recording", ["task": "Book a flight"])
        XCTAssertTrue(refused.isError)
        let starts = await host.agentStarts
        XCTAssertTrue(starts.isEmpty)
    }

    func testRecordingStartsAndStops() async throws {
        let (mcp, host) = server()
        let started = await call(mcp, "start_recording", ["for": "launch", "title": "Signup"])
        XCTAssertFalse(started.isError, started.text)
        let live = await host.isRecording()
        XCTAssertTrue(live)
        let take = try XCTUnwrap(library.takes().first)
        XCTAssertEqual(take.customTitle(), "Signup")
        XCTAssertEqual(TakePlan.load(for: take)?.purposeID, "launch")
        let again = await call(mcp, "start_recording")
        XCTAssertTrue(again.isError)

        // The app transcribes after stop; here the transcript is already there.
        FileManager.default.createFile(atPath: take.transcriptFailedURL.path, contents: Data("{}".utf8))
        let stopped = await call(mcp, "stop_recording")
        XCTAssertFalse(stopped.isError, stopped.text)
        let job = await mcp.board.jobs.first
        XCTAssertEqual(job?.state, .done)
        XCTAssertTrue(VisionOneMCP.same(job?.takeFolder, take.folder))
    }

    func testExportThenShareAsksEveryTime() async throws {
        try makeTake()
        let (mcp, host) = server(answer: MCPAnswer(.allowForSession))
        let early = await call(mcp, "share_video", ["to": "whatsapp"])
        XCTAssertTrue(early.isError, "nothing exported yet")

        let exported = await call(mcp, "export_video", ["preset": "whatsapp"])
        XCTAssertFalse(exported.isError, exported.text)
        XCTAssertTrue(exported.text.contains("(WhatsApp).mp4"))

        _ = await call(mcp, "share_video", ["to": "whatsapp"])
        _ = await call(mcp, "share_video", ["to": "whatsapp"])
        let asked = await host.questions.filter { $0.action == .share }.count
        XCTAssertEqual(asked, 2, "a share is never remembered")
        let shared = await host.shared.count
        XCTAssertEqual(shared, 2)
    }

    // MARK: Resources

    func testResourcesReadTakesAndTranscripts() async throws {
        let take = try makeTake()
        let (mcp, _) = server()
        let resources = await mcp.resources()
        XCTAssertTrue(resources.contains { $0.uri == "visionone://takes" })
        let uri = VisionOneMCP.uri(for: take)
        XCTAssertTrue(uri.contains("%20"))
        XCTAssertTrue(resources.contains { $0.uri == uri + "/transcript" })
        let transcript = try await mcp.read(uri + "/transcript")
        XCTAssertTrue(transcript.text.contains("Welcome to the demo."))
        let summary = try await mcp.read(uri)
        XCTAssertTrue(summary.text.contains(take.name))
        do {
            _ = try await mcp.read("visionone://takes/nope")
            XCTFail("should throw")
        } catch let error as MCPError {
            XCTAssertEqual(error.code, -32002)
        }
    }

    // MARK: Permissions

    func testPermissionsNeverRememberShares() async {
        let permissions = MCPPermissions()
        await permissions.allowAll(claude.id)
        let record = await permissions.allows(claude, .record)
        let share = await permissions.allows(claude, .share)
        XCTAssertTrue(record)
        XCTAssertFalse(share)
        await permissions.allow(claude, .share)
        let stillNo = await permissions.allows(claude, .share)
        XCTAssertFalse(stillNo)
        await permissions.askFirst(claude.id)
        let asking = await permissions.allows(claude, .record)
        XCTAssertFalse(asking)
    }

    // MARK: Socket

    func testLineBufferSplitsAcrossReads() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(buffer.append(Data(":2}\r\n\n".utf8)), [Data("{\"b\":2}".utf8)])
    }

    func testSocketServerAnswersOverTheSocket() throws {
        let path = "/tmp/v1-\(UUID().uuidString.prefix(8)).sock"
        let (mcp, _) = server()
        let socketServer = MCPSocketServer(path: path) { MCPSession(server: mcp) }
        try socketServer.start()
        defer { socketServer.stop() }
        var mode = stat()
        XCTAssertEqual(stat(path, &mode), 0)
        XCTAssertEqual(mode.st_mode & 0o777, 0o600)

        let fd = UnixSocket.connect(to: path)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        var line = ping.encodedLine()
        line.append(10)
        XCTAssertTrue(UnixSocket.writeAll(fd, line))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(buffer[0..<max(count, 0)]).dropLast())
        XCTAssertEqual(reply["id"], 1)
        XCTAssertEqual(reply["result"], .object([:]))
    }

    func testSocketServerAnswersAfterTheAgentStopsSending() throws {
        let path = "/tmp/v1-\(UUID().uuidString.prefix(8)).sock"
        let (mcp, _) = server()
        let socketServer = MCPSocketServer(path: path) { MCPSession(server: mcp) }
        try socketServer.start()
        defer { socketServer.stop() }
        let fd = UnixSocket.connect(to: path)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let first: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        let second: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        var lines = first.encodedLine()
        lines.append(10)
        lines.append(second.encodedLine())
        lines.append(10)
        XCTAssertTrue(UnixSocket.writeAll(fd, lines))
        shutdown(fd, SHUT_WR)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
        }
        var parser = LineBuffer()
        let ids = parser.append(received).compactMap { (try? JSONDecoder().decode(JSONValue.self, from: $0))?["id"] }
        XCTAssertEqual(Set(ids.compactMap(\.intValue)), [1, 2], "both answered, then the app hung up")
    }

    func testBridgeAnswersWithAPlainErrorWhenTheAppIsClosed() throws {
        let reply = try XCTUnwrap(MCPBridge.offlineReply(to: Data(#"{"jsonrpc":"2.0","id":5,"method":"initialize"}"#.utf8)))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: reply)
        XCTAssertEqual(parsed["id"], 5)
        XCTAssertTrue(parsed["error"]?["message"]?.stringValue?.contains("Vision One") == true)
        XCTAssertNil(MCPBridge.offlineReply(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
    }
}
