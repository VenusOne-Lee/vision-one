import Foundation

/// Runs the agents as jobs on the board: each gets steps, a receipt and
/// the changes it made, and any approval waits on its task. The app, the
/// after-Stop flow and the MCP server all start agents through here.
public struct AgentRunner: Sendable {
    public let board: AgentJobBoard
    public let ladder: AILadder
    /// Called as each job goes on the board, before it starts, so the Desk
    /// can put it in its task (and its approvals land there).
    public var onJobAdded: (@Sendable (AgentJob) async -> Void)?

    public init(board: AgentJobBoard, ladder: AILadder, onJobAdded: (@Sendable (AgentJob) async -> Void)? = nil) {
        self.board = board
        self.ladder = ladder
        self.onJobAdded = onJobAdded
    }

    // MARK: Producer

    /// Reads the project's sources and drafts a script. The script comes
    /// back with the job; nothing is written into a take.
    public func script(sources: ScriptSources?, refs: [ScriptSourceRef], brief: AgentBrief,
                       ask: String? = nil) async -> (AgentJob, ProducerAgent.Script?) {
        let job = AgentJob(agent: .producer, title: "Draft a script", ask: ask,
                           steps: ["Read what's new", "Write the script"])
        let box = ScriptBox()
        let done = await run(job) { id in
            await board.step(id, 0)
            var items: [ScriptSourceItem] = []
            var skipped: [String] = []
            if let sources, !refs.isEmpty {
                let fetched = await sources.fetch(refs)
                items = fetched.items
                skipped = fetched.failures.map { "\($0.key.title): \($0.value)" }.sorted()
            }
            await board.step(id, 1)
            let script = try await ProducerAgent(ladder: ladder).script(from: items, brief: brief, ask: ask)
            await box.set(script)
            var receipt = items.isEmpty
                ? "Wrote a \(script.lines.count)-line script."
                : "Wrote a \(script.lines.count)-line script from \(items.count) \(items.count == 1 ? "update" : "updates")."
            if !skipped.isEmpty { receipt += " Skipped " + skipped.joined(separator: "; ") + "." }
            return (receipt, [])
        }
        return (done, await box.value)
    }

    // MARK: Editor

    /// `version` runs it on a copy of the cut (Try in a copy) instead of the main one.
    @discardableResult
    public func edit(_ take: Take, brief: AgentBrief, goal: EditorAgent.Goal, energy: Energy,
                     title: String? = nil, version: TakeVersion? = nil) async -> AgentJob {
        var job = AgentJob(agent: .editor, title: title ?? "Edit \(Self.name(of: take))", take: take, ask: goal.ask,
                           steps: ["Read the transcript", "Ask which sentences to keep", "Propose cuts"])
        let editsURL = version.map { TakeVersions.url(of: $0, in: take) } ?? take.editsURL
        if let version, !version.isMain { job.editsFile = version.file }
        return await run(job) { id in
            await board.step(id, 0)
            let transcript = try Transcript.read(from: take.transcriptURL)
            var list = try EditList.load(from: editsURL, sourceDuration: transcript.duration)
            await board.step(id, 1)
            let proposals = try await EditorAgent(ladder: ladder)
                .propose(transcript: transcript, edits: list, brief: brief, goal: goal, energy: energy)
            await board.step(id, 2)
            let added = list.propose(proposals)
            try list.write(to: editsURL)
            return (AgentReceipt.cuts(added, ask: goal.ask), added.map { AgentJob.Change.cut($0.id) })
        }
    }

    // MARK: Clipper

    @discardableResult
    public func clips(_ take: Take, brief: AgentBrief, format: ClipFormat = .vertical, count: Int = 3) async -> AgentJob {
        let job = AgentJob(agent: .clipper, title: "Make \(count) clips", take: take,
                           steps: ["Find moments that stand alone", "Score them", "Write titles", "Add them to Clips"])
        return await run(job) { id in
            await board.step(id, 0)
            let transcript = try Transcript.read(from: take.transcriptURL)
            let edits = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
            // The on-device finder's windows first; plain sentence windows if it found none.
            var candidates = ClipFinder().candidates(transcript: transcript, edits: edits).map(ClipCandidate.init)
            if candidates.isEmpty {
                candidates = ClipperAgent.candidates(from: transcript.sentences(keeping: edits))
            }
            guard !candidates.isEmpty else {
                return ("This take is too short for clips of 15 seconds or more.", [])
            }
            await board.step(id, 1)
            // pick() scores, then titles; the titles step shows once scoring is back.
            let picks = try await ClipperAgent(ladder: ladder)
                .pick(from: candidates, brief: brief, count: count, format: format.rawValue)
            await board.step(id, 3)
            var list = try ClipList.load(from: take.clipsURL)
            let added = list.propose(picks.map(\.clip), sourceDuration: transcript.duration)
            try list.write(to: take.clipsURL)
            if !picks.isEmpty, added.isEmpty { return ("These clips are already in Clips.", []) }
            return (AgentReceipt.clips(added), added.map { AgentJob.Change.clip($0.id) })
        }
    }

    // MARK: Sharer

    @discardableResult
    public func share(_ take: Take, brief: AgentBrief, launch: Bool = false, product: String? = nil) async -> AgentJob {
        let job = AgentJob(agent: .sharer, title: launch ? "Write the launch post" : "Write title and posts", take: take,
                           steps: ["Read the edited transcript", "Write title, chapters and posts", "Save drafts"])
        return await run(job) { id in
            await board.step(id, 0)
            let transcript = try Transcript.read(from: take.transcriptURL)
            let edits = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
            await board.step(id, 1)
            do {
                let pack = try await SharerAgent(ladder: ladder)
                    .draft(transcript: transcript, edits: edits, brief: brief, product: product, launch: launch)
                await board.step(id, 2)
                try pack.write(for: take)
                return (AgentReceipt.share(pack), [AgentJob.Change.sharePack])
            } catch let reason as SharerAgent.TooLittleSaid {
                // A successful recording with no/short speech is not a failed
                // AI job. Preserve any existing drafts and offer manual copy.
                return (reason.recoveryMessage, [])
            }
        }
    }

    // MARK: After Stop

    /// Which agents start on their own once a take is transcribed. The
    /// Energy dial doubles as "how much is automatic": Calm only tidies,
    /// Lively also drafts the posts, Viral also finds clips.
    public static func automaticAgents(for plan: TakePlan) -> [AgentKind] {
        let purpose = plan.purpose
        var agents: [AgentKind] = [.editor]
        if plan.energy != .calm, !(purpose.prompts["post"] ?? "").isEmpty { agents.append(.sharer) }
        if plan.energy == .viral || purpose.id == "short", !(purpose.prompts["clip"] ?? "").isEmpty {
            agents.append(.clipper)
        }
        return agents
    }

    /// Starts the automatic agents one after another and returns their
    /// jobs. Call it when the transcript is ready. Everything they make
    /// waits as dashed proposals; nothing is posted.
    @discardableResult
    public func afterRecording(_ take: Take, plan: TakePlan, brief: AgentBrief) async -> [AgentJob] {
        var done: [AgentJob] = []
        for agent in Self.automaticAgents(for: plan) {
            switch agent {
            case .editor:
                done.append(await edit(take, brief: brief, goal: EditorAgent.Goal(targetSeconds: plan.targetSeconds),
                                       energy: plan.energy, title: "Tidy \(Self.name(of: take))"))
            case .clipper:
                let format = plan.purpose.formats.compactMap(ClipFormat.init(rawValue:)).first ?? .vertical
                done.append(await clips(take, brief: brief, format: format))
            case .sharer:
                done.append(await share(take, brief: brief,
                                        launch: plan.purposeID == "launch" || plan.purposeID == "update"))
            case .producer, .autopilot:
                break
            }
            // A "no" on one job stops the rest: the user said not now.
            if done.last?.state == .cancelled { break }
        }
        return done
    }

    // MARK: Running

    private func run(_ planned: AgentJob,
                     _ work: @escaping @Sendable (UUID) async throws -> (String, [AgentJob.Change])) async -> AgentJob {
        let job = Self.fromOrigin(planned)
        await board.add(job)
        await onJobAdded?(job)
        await AgentJobContext.$jobID.withValue(job.id) {
            do {
                let (receipt, changes) = try await work(job.id)
                await board.finish(job.id, receipt: receipt, changes: changes)
            } catch AIError.notApproved {
                await board.cancel(job.id)
            } catch {
                await board.fail(job.id, Self.message(for: error))
            }
        }
        return await board.job(job.id) ?? job
    }

    /// A job started by an agent over MCP takes the id that agent is
    /// watching for, and says who asked.
    static func fromOrigin(_ job: AgentJob) -> AgentJob {
        guard let origin = MCPJobContext.origin else { return job }
        var copy = AgentJob(id: origin.jobID, agent: job.agent, title: job.title, take: job.take, ask: job.ask,
                            steps: job.steps.map(\.title), createdAt: job.createdAt)
        copy.editsFile = job.editsFile
        copy.requestedBy = origin.requestedBy
        return copy
    }

    /// "launch video" from the take's plan, else the folder's date name.
    static func name(of take: Take) -> String {
        TakePlan.load(for: take).map { "\($0.purpose.title.lowercased()) video" } ?? take.name
    }

    /// Plain words for an agent error, for the task's "didn't finish" line.
    public static func message(for error: Error) -> String {
        switch error as? AIError {
        case .noProvider?:
            return "No AI is set up for this. Turn on Apple Intelligence, sign in with ChatGPT, or add a key in AI settings."
        case .notApproved?:
            return "Not sent. Nothing left your Mac."
        case let .unavailable(_, why)?:
            return why
        case .usageLimit?:
            return "Every rung that's set up has hit its usage limit. Try again later or add a key."
        case .tooLong?:
            return "This take is too long for the AI that's set up. Sign in with ChatGPT or add a key."
        case let .refused(_, why)?:
            return why.isEmpty ? "The model declined this one." : why
        case let .http(_, status, message)?:
            return "The AI service said \(status): \(message)"
        case let .badResponse(_, why)?:
            return "The reply didn't make sense (\(why)). Try again."
        case nil:
            if error is DecodingError { return "The reply didn't make sense. Try again." }
            if (error as? CocoaError)?.code == .fileReadNoSuchFile { return "The transcript isn't ready yet." }
            return error.localizedDescription
        }
    }
}

private actor ScriptBox {
    var value: ProducerAgent.Script?
    func set(_ script: ProducerAgent.Script) { value = script }
}

