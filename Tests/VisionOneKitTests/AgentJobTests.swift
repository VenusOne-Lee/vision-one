import XCTest
@testable import VisionOneKit

final class AgentJobTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A take with "Welcome. Sorry my cat. Click export." on disk.
    func makeTake() throws -> Take {
        let take = Take(folder: folder)
        var words: [TranscriptWord] = []
        var t = 0.0
        for sentence in ["Welcome to the demo.", "Sorry my cat is here.", "Click export and you're done."] {
            for w in sentence.split(separator: " ") {
                words.append(TranscriptWord(id: words.count, text: String(w), start: t, end: t + 0.9))
                t += 1
            }
        }
        let transcript = Transcript(language: "en", engine: "test", duration: t, segments: [TranscriptSegment(words: words)])
        try transcript.write(to: take.transcriptURL)
        return take
    }

    let keepReply: (AIRequest) -> String = { _ in
        #"[{"name":"s0","probability":0.9},{"name":"s1","probability":0.05},{"name":"s2","probability":0.95}]"#
    }

    func runner(board: AgentJobBoard, fallback: OutboundDecision = .deny,
                reply: @escaping (AIRequest) -> String) -> AgentRunner {
        let gate = OutboundGate(approver: board.approver(fallback: FixedApprover(fallback)))
        let ladder = AILadder(providers: [FakeProvider(.chatGPT, rung: .chatGPT, reply: reply)], gate: gate)
        return AgentRunner(board: board, ladder: ladder)
    }

    func waitFor(_ board: AgentJobBoard, _ state: AgentJob.State) async throws -> AgentJob {
        for _ in 0..<500 {
            if let job = await board.jobs.first, job.state == state { return job }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Job never reached \(state)")
        throw CancellationError()
    }

    func testEditJobParksApprovalOnTheTaskThenNeedsReview() async throws {
        let take = try makeTake()
        let board = AgentJobBoard()
        let runner = runner(board: board, reply: keepReply)
        let running = Task { await runner.edit(take, brief: Purpose.demo.brief(), goal: .init(), energy: .lively) }

        let waiting = try await waitFor(board, .needsApproval)
        XCTAssertEqual(waiting.approval?.destination, "fake.example")
        XCTAssertEqual(waiting.statusLine, "Editor · waiting for approval")
        let needsYou = await board.needsYou
        XCTAssertEqual(needsYou.count, 1)
        await board.resolveApproval(jobID: waiting.id, decision: .allowOnce)

        let job = await running.value
        XCTAssertEqual(job.state, .needsReview)
        XCTAssertNil(job.approval)
        XCTAssertEqual(job.changes.count, 1)
        XCTAssertEqual(job.receipt, "Cut 5 s across 1 part.")
        XCTAssertTrue(job.steps.allSatisfy { $0.state == .done })

        try await board.keep(job.id)
        let edits = try EditList.read(from: take.editsURL)
        XCTAssertEqual(edits.cuts.map(\.state), [.accepted])
        let kept = await board.job(job.id)
        XCTAssertEqual(kept?.state, .done)
    }

    func testDenyCancelsTheJobAndWritesNothing() async throws {
        let take = try makeTake()
        let board = AgentJobBoard()
        let runner = runner(board: board, reply: keepReply)
        let running = Task { await runner.edit(take, brief: Purpose.demo.brief(), goal: .init(), energy: .lively) }
        let waiting = try await waitFor(board, .needsApproval)
        await board.resolveApproval(jobID: waiting.id, decision: .deny)
        let job = await running.value
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.editsURL.path))
    }

    func testUndoRemovesTheJobsCuts() async throws {
        let take = try makeTake()
        let board = AgentJobBoard()
        let runner = runner(board: board, reply: keepReply)
        let running = Task { await runner.edit(take, brief: Purpose.demo.brief(), goal: .init(), energy: .lively) }
        let waiting = try await waitFor(board, .needsApproval)
        await board.resolveApproval(jobID: waiting.id, decision: .allowForSession)
        let job = await running.value
        try await board.undo(job.id)
        XCTAssertTrue(try EditList.read(from: take.editsURL).cuts.isEmpty)
        let undone = await board.job(job.id)
        XCTAssertEqual(undone?.state, .undone)
    }

    func testApprovalsOutsideAJobUseTheFallback() async throws {
        let board = AgentJobBoard()
        let approver = board.approver(fallback: FixedApprover(.allowOnce))
        let request = OutboundRequest(provider: .chatGPT, providerName: "ChatGPT", destination: "x",
                                      task: .sharePack, summary: "s", payload: "p")
        let decision = await approver.approve(request)
        XCTAssertEqual(decision, .allowOnce)
        let jobs = await board.jobs
        XCTAssertTrue(jobs.isEmpty)
    }

    func testPanelCanAnswerAJobsApproval() async throws {
        let take = try makeTake()
        let board = AgentJobBoard()
        let gate = OutboundGate(approver: board.approver(fallback: FixedApprover(.allowOnce), panelForJobs: true))
        let ladder = AILadder(providers: [FakeProvider(.chatGPT, rung: .chatGPT, reply: keepReply)], gate: gate)
        let job = await AgentRunner(board: board, ladder: ladder)
            .edit(take, brief: Purpose.demo.brief(), goal: .init(), energy: .lively)
        XCTAssertEqual(job.state, .needsReview)
    }

    func testFailedJobExplainsWhy() async throws {
        let board = AgentJobBoard()
        let runner = runner(board: board, fallback: .allowOnce, reply: keepReply)
        let job = await runner.edit(Take(folder: folder), brief: Purpose.demo.brief(), goal: .init(), energy: .calm)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.error, "The transcript isn't ready yet.")
        XCTAssertEqual(job.steps.first?.state, .failed)
    }

    func testBoardSavesAndMarksInterruptedJobs() async throws {
        let url = folder.appendingPathComponent("jobs.json")
        let board = AgentJobBoard(storeURL: url)
        var running = AgentJob(agent: .clipper, title: "Make 3 clips", steps: ["a", "b"])
        running.state = .running
        await board.add(running)
        await board.add(AgentJob(agent: .sharer, title: "Write title and posts"))
        await board.update(running.id) { $0.receipt = "x" }

        let reloaded = AgentJobBoard(storeURL: url)
        let jobs = await reloaded.jobs
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.first { $0.id == running.id }?.state, .failed)
        XCTAssertEqual(jobs.first { $0.id == running.id }?.receipt, "x")
    }

    func testUpdatesStreamSendsCurrentListFirst() async throws {
        let board = AgentJobBoard()
        await board.add(AgentJob(agent: .editor, title: "One"))
        var iterator = await board.updates().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.map(\.title), ["One"])
        await board.add(AgentJob(agent: .editor, title: "Two"))
        let second = await iterator.next()
        XCTAssertEqual(second?.map(\.title), ["Two", "One"])
    }

    func testStatusLinesAndReceipts() {
        var job = AgentJob(agent: .clipper, title: "Make 3 clips", steps: ["a", "b", "c", "d", "e"])
        job.state = .running
        job.steps[0].state = .done
        job.steps[1].state = .done
        job.steps[2].state = .running
        XCTAssertEqual(job.statusLine, "Clipper · running, step 3 of 5")
        XCTAssertEqual(AgentReceipt.duration(21), "21 s")
        XCTAssertEqual(AgentReceipt.duration(65), "1 min 5 s")
        XCTAssertEqual(AgentReceipt.cuts([]), "Nothing more to cut.")
    }

    func testAutomaticAgentsFollowTheEnergyDial() {
        XCTAssertEqual(AgentRunner.automaticAgents(for: TakePlan(purposeID: "demo", energy: .calm)), [.editor])
        XCTAssertEqual(AgentRunner.automaticAgents(for: TakePlan(purposeID: "demo", energy: .lively)), [.editor, .sharer])
        XCTAssertEqual(AgentRunner.automaticAgents(for: TakePlan(purpose: .short)), [.editor, .sharer, .clipper])
        // Bug reports have no clip prompt, so even Viral finds no clips.
        XCTAssertEqual(AgentRunner.automaticAgents(for: TakePlan(purposeID: "bugReport", energy: .viral)), [.editor, .sharer])
    }
}
