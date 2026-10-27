import XCTest
@testable import VisionOneKit

/// Counts how often the floating panel was asked.
actor CountingApprover: OutboundApprover {
    private(set) var asked = 0
    let decision: OutboundDecision

    init(_ decision: OutboundDecision) { self.decision = decision }

    func approve(_ request: OutboundRequest) async -> OutboundDecision {
        asked += 1
        return decision
    }
}

actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// A panel nobody answers: it waits until it's cancelled, then hands back
/// the "no" a dismissed panel would.
struct UnansweredPanel: OutboundApprover {
    let cancelled: Flag

    func approve(_ request: OutboundRequest) async -> OutboundDecision {
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        await cancelled.set()
        return .deny
    }
}

final class ApprovalSurfaceTests: XCTestCase {
    let request = OutboundRequest(provider: .chatGPT, providerName: "ChatGPT", destination: "api.openai.com",
                                  task: .sharePack, summary: "Title and posts", payload: "words")

    func waitForApproval(_ board: AgentJobBoard, _ id: UUID) async throws {
        for _ in 0..<500 {
            if await board.job(id)?.state == .needsApproval { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Job never waited for approval")
        throw CancellationError()
    }

    // MARK: Routing

    func testAskedOnceWhenTheWindowIsInFront() {
        XCTAssertEqual(ApprovalSurface.route(onTask: true, windowInFront: true), .thread)
        XCTAssertEqual(ApprovalSurface.route(onTask: true, windowInFront: false), .threadAndPanel)
        XCTAssertEqual(ApprovalSurface.route(onTask: false, windowInFront: true), .panel)
        XCTAssertEqual(ApprovalSurface.route(onTask: false, windowInFront: false), .panel)
        XCTAssertFalse(ApprovalSurface.thread.showsPanel)
        XCTAssertTrue(ApprovalSurface.threadAndPanel.showsPanel)
        XCTAssertTrue(ApprovalSurface.panel.showsPanel)
    }

    func testDeskFindsTheTaskAJobIsFiledUnder() async {
        let board = AgentJobBoard()
        let desk = Desk(board: board)
        let jobID = UUID()
        let none = await desk.taskID(forJob: jobID)
        XCTAssertNil(none)
        let task = await desk.newTask(title: "Demo")
        await desk.attach(jobID: jobID, to: task.id)
        let found = await desk.taskID(forJob: jobID)
        XCTAssertEqual(found, task.id)
        await desk.archive(task.id)
        let archived = await desk.taskID(forJob: jobID)
        XCTAssertNil(archived, "an archived task's card isn't in view")
    }

    // MARK: One pending approval

    func testCardInViewMeansThePanelNeverAsks() async throws {
        let board = AgentJobBoard()
        let panel = CountingApprover(.allowOnce)
        let approver = board.approver(fallback: panel, panelFor: { _ in false })
        let job = await board.add(AgentJob(agent: .sharer, title: "Write title and posts"))
        let request = self.request
        let asking = Task {
            await AgentJobContext.$jobID.withValue(job.id) { await approver.approve(request) }
        }
        try await waitForApproval(board, job.id)
        await board.resolveApproval(jobID: job.id, decision: .allowForSession)
        let decision = await asking.value
        XCTAssertEqual(decision, .allowForSession)
        let asked = await panel.asked
        XCTAssertEqual(asked, 0)
    }

    func testPanelAnswersTheSameApprovalWhenTheWindowIsAway() async throws {
        let board = AgentJobBoard()
        let panel = CountingApprover(.allowOnce)
        let approver = board.approver(fallback: panel, panelFor: { _ in true })
        let job = await board.add(AgentJob(agent: .sharer, title: "Write title and posts"))
        let request = self.request
        let decision = await AgentJobContext.$jobID.withValue(job.id) { await approver.approve(request) }
        XCTAssertEqual(decision, .allowOnce)
        let asked = await panel.asked
        XCTAssertEqual(asked, 1)
        let after = await board.job(job.id)
        XCTAssertNil(after?.approval, "answering the panel clears the task's card")
    }

    func testAnsweringTheCardTakesThePanelAwayAndItsLateNoIsIgnored() async throws {
        let board = AgentJobBoard()
        let cancelled = Flag()
        let approver = board.approver(fallback: UnansweredPanel(cancelled: cancelled), panelFor: { _ in true })
        let job = await board.add(AgentJob(agent: .sharer, title: "Write title and posts"))
        let request = self.request
        let first = Task {
            await AgentJobContext.$jobID.withValue(job.id) { await approver.approve(request) }
        }
        try await waitForApproval(board, job.id)
        await board.resolveApproval(jobID: job.id, decision: .allowOnce)
        let decision = await first.value
        XCTAssertEqual(decision, .allowOnce)
        for _ in 0..<500 {
            if await cancelled.isSet { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let wasCancelled = await cancelled.isSet
        XCTAssertTrue(wasCancelled, "the panel is told to go away")

        // The next approval on the same job waits for its own answer.
        let second = Task {
            await AgentJobContext.$jobID.withValue(job.id) {
                await board.requestApproval(jobID: job.id, request: request)
            }
        }
        try await waitForApproval(board, job.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        let still = await board.job(job.id)
        XCTAssertEqual(still?.state, .needsApproval)
        await board.resolveApproval(jobID: job.id, decision: .allowOnce)
        let secondDecision = await second.value
        XCTAssertEqual(secondDecision, .allowOnce)
    }

    // MARK: Outside agents

    func testAgentRequestReadsAsTheAgentsQuestion() {
        let question = MCPQuestion(action: .record, client: MCPClient(name: "claude-code"),
                                   title: "Record your screen for Claude Code?",
                                   details: [MCPQuestion.Detail("For", "Demo")])
        let approval = AgentJob.Approval(question, destination: "This Mac")
        let card = ApprovalCard.job(UUID(), approval: approval, agent: .producer, project: "My videos")
        XCTAssertEqual(card.question, "Record your screen for Claude Code?")
        XCTAssertEqual(card.options.map(\.effect), [.allowOnce, .allowAlways, .deny])
        XCTAssertEqual(card.options.last?.label, "No, and tell Claude Code what to do instead")

        let share = MCPQuestion(action: .share, client: MCPClient(name: "claude-code"),
                                title: "Post to LinkedIn for Claude Code?", preview: "Shipped it.")
        let shareCard = ApprovalCard.job(UUID(), approval: AgentJob.Approval(share, destination: "LinkedIn"),
                                         agent: .sharer, project: "My videos")
        XCTAssertEqual(shareCard.options.map(\.effect), [.allowOnce, .deny], "shares always ask")
        XCTAssertEqual(shareCard.detail, "Shipped it.")
    }

    func testBoardKeepsTheNoteForTheAgentOnce() async throws {
        let board = AgentJobBoard()
        let job = await board.add(AgentJob(agent: .producer, title: "Record a take"))
        let request = self.request
        let asking = Task { await board.requestApproval(jobID: job.id, request: request) }
        try await waitForApproval(board, job.id)
        await board.resolveApproval(jobID: job.id, decision: .deny, note: "  record the browser only ")
        let decision = await asking.value
        XCTAssertEqual(decision, .deny)
        let note = await board.takeNote(jobID: job.id)
        XCTAssertEqual(note, "record the browser only")
        let again = await board.takeNote(jobID: job.id)
        XCTAssertNil(again)
    }
}
