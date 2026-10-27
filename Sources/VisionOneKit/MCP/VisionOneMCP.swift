import Foundation

/// Vision One as an MCP server: the tools and resources Claude Code, Codex
/// or any agent can use. Reading and drafting just happen; recording,
/// keeping changes and sharing wait for the user's yes in Vision One. Each
/// call that does work is a task on the agent board, marked with who
/// asked, so it shows in the app like any other. See docs/MCP.md.
public final class VisionOneMCP: Sendable {
    public let library: TakeLibrary
    public let board: AgentJobBoard
    /// Files each call's jobs under a task, marked with who asked.
    public let desk: Desk?
    public let host: any VisionOneMCPHost
    public let permissions: MCPPermissions
    public let version: String
    /// How long a tool waits before handing back a task_id to wait on.
    /// Codex gives a tool 60 seconds.
    public let patience: Double

    public init(library: TakeLibrary, board: AgentJobBoard, desk: Desk? = nil, host: any VisionOneMCPHost,
                permissions: MCPPermissions = MCPPermissions(), version: String = "0.1", patience: Double = 40) {
        self.library = library
        self.board = board
        self.desk = desk
        self.host = host
        self.permissions = permissions
        self.version = version
        self.patience = patience
    }

    var info: JSONValue {
        ["name": "vision-one", "title": "Vision One", "version": .string(version)]
    }

    /// A message for the model, sent back as a tool error.
    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: Calling

    public func call(_ name: String, arguments args: [String: JSONValue], client: MCPClient) async -> MCPToolResult {
        do {
            switch name {
            case "list_takes": return listTakes(args)
            case "get_take": return try await getTake(args)
            case "read_transcript": return try await readTranscript(args)
            case "list_tasks": return try await listTasks(args)
            case "wait_for_task": return try await waitForTask(args)
            case "recording_status": return await recordingStatus()
            case "start_recording": return try await startRecording(args, client: client)
            case "stop_recording": return try await stopRecording()
            case "clean_up": return try await cleanUp(args, client: client)
            case "cut_to_length": return try await cutToLength(args, client: client)
            case "cut_part": return try await cutPart(args, client: client)
            case "make_clips": return try await makeClips(args, client: client)
            case "draft_posts": return try await draftPosts(args, client: client)
            case "keep_changes": return try await keepChanges(args, client: client)
            case "undo_changes": return try await undoChanges(args)
            case "write_captions": return try await writeCaptions(args)
            case "export_video": return try await exportVideo(args, client: client)
            case "share_video": return try await shareVideo(args, client: client)
            case "rename_take": return try renameTake(args)
            case "list_demos": return await listDemos(args)
            case "rerecord_demo": return try await rerecordDemo(args, client: client)
            default: return .failed("Vision One has no tool called \(name).")
            }
        } catch let failure as Failure {
            return .failed(failure.message)
        } catch {
            return .failed(AgentRunner.message(for: error))
        }
    }

    // MARK: Reading

    func listTakes(_ args: [String: JSONValue]) -> MCPToolResult {
        let filter = args["filter"]?.stringValue.flatMap(LibraryFilter.init(rawValue:)) ?? .all
        let query = LibraryQuery(search: args["search"]?.stringValue ?? "", filter: filter)
        let limit = min(max(args["limit"]?.intValue ?? 20, 1), 100)
        let all = library.takes().map(listing)
        let found = query.apply(to: all)
        let text: String
        if all.isEmpty {
            text = "No takes yet. Record one with start_recording."
        } else if found.isEmpty {
            text = "No takes match."
        } else {
            let count = "\(found.count) \(found.count == 1 ? "take" : "takes")"
            text = found.count > limit ? "\(count), showing the first \(limit)." : "\(count)."
        }
        return .done(text, ["takes": .array(found.prefix(limit).map(listingJSON))])
    }

    func getTake(_ args: [String: JSONValue]) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        var data = summary(take)
        let jobs = await board.jobs(for: take)
        if case var .object(object) = data {
            object["tasks"] = .array(jobs.prefix(10).map(jobJSON))
            data = .object(object)
        }
        return .done("“\(take.displayTitle())”", data)
    }

    func readTranscript(_ args: [String: JSONValue]) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        let transcript = try await transcript(of: take)
        let edits = (try? EditList.load(from: take.editsURL, sourceDuration: transcript.duration))
            ?? EditList(sourceDuration: transcript.duration)
        let keptOnly = args["kept_only"]?.boolValue ?? false
        let lines = Self.transcriptLines(transcript, edits: edits, keptOnly: keptOnly)
        var head = "“\(take.displayTitle())”, \(AgentReceipt.duration(transcript.duration))"
        if edits.outputDuration < transcript.duration - 0.5 {
            head += ", \(AgentReceipt.duration(edits.outputDuration)) after cuts"
        }
        head += "."
        if !keptOnly, edits.cuts.contains(where: { $0.state != .rejected }) {
            head += " Words in ~~ ~~ are cut; words in [ ] are proposed cuts."
        }
        let body = lines.isEmpty ? "Nothing was said in this take." : lines.joined(separator: "\n")
        return .done(head + "\n\n" + body)
    }

    /// One line per segment: "0:12  So here's the signup page".
    static func transcriptLines(_ transcript: Transcript, edits: EditList, keptOnly: Bool) -> [String] {
        let proposed = edits.cuts.filter { $0.state == .proposed }.map(\.span)
        var lines: [String] = []
        for segment in transcript.segments {
            var words: [String] = []
            var first: Double?
            for word in segment.words {
                let middle = (word.start + word.end) / 2
                let cut = edits.isRemoved(middle)
                if keptOnly, cut { continue }
                if first == nil { first = word.start }
                if cut {
                    words.append("~~\(word.text)~~")
                } else if !keptOnly, proposed.contains(where: { $0.contains(middle) }) {
                    words.append("[\(word.text)]")
                } else {
                    words.append(word.text)
                }
            }
            if let first, !words.isEmpty {
                lines.append("\(clock(first))  " + words.joined(separator: " "))
            }
        }
        return lines
    }

    func listTasks(_ args: [String: JSONValue]) async throws -> MCPToolResult {
        var jobs = await board.jobs
        if let name = args["take"]?.stringValue, !name.isEmpty {
            let take = try resolveTake(["take": .string(name)])
            jobs = jobs.filter { Self.same($0.takeFolder, take.folder) }
        }
        if args["active_only"]?.boolValue == true {
            jobs = jobs.filter { $0.state.isActive || $0.state.needsYou }
        }
        let limit = min(max(args["limit"]?.intValue ?? 20, 1), 100)
        let waiting = jobs.filter(\.state.needsYou).count
        var text = jobs.isEmpty ? "No tasks." : "\(jobs.count) \(jobs.count == 1 ? "task" : "tasks")"
        if !jobs.isEmpty { text += waiting > 0 ? ", \(waiting) waiting for the user." : "." }
        return .done(text, ["tasks": .array(jobs.prefix(limit).map(jobJSON))])
    }

    func waitForTask(_ args: [String: JSONValue]) async throws -> MCPToolResult {
        let id = try taskID(args)
        guard await board.job(id) != nil else { throw Failure("There's no task with that id. list_tasks shows them.") }
        let seconds = min(max(args["seconds"]?.doubleValue ?? 30, 1), 45)
        guard let job = await settle(id, within: seconds) else { throw Failure("That task is gone.") }
        return describe(job)
    }

    func recordingStatus() async -> MCPToolResult {
        guard await host.isRecording() else { return .done("Not recording.", ["recording": false]) }
        let job = await board.jobs.first { $0.agent == .producer && $0.state.isActive && $0.takeFolder != nil }
        var data: [String: JSONValue] = ["recording": true]
        if let take = job?.take { data["take"] = .string(take.name) }
        return .done("Recording.", .object(data))
    }

    // MARK: Recording

    func startRecording(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        guard !(await host.isRecording()) else {
            throw Failure("Vision One is already recording. Call stop_recording first.")
        }
        let purpose = try args["for"]?.stringValue.flatMap { raw -> Purpose? in
            let wanted = raw.trimmingCharacters(in: .whitespaces)
            if wanted.isEmpty { return nil }
            if let match = Purpose.all.first(where: {
                $0.id.caseInsensitiveCompare(wanted) == .orderedSame || $0.title.caseInsensitiveCompare(wanted) == .orderedSame
            }) { return match }
            throw Failure("“\(wanted)” isn't something Vision One records for. Use one of: "
                + Purpose.all.map(\.id).joined(separator: ", ") + ".")
        }
        let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = (title?.isEmpty == false) ? title : nil
        let job = await addJob(AgentJob(agent: .producer, title: named.map { "Record “\($0)”" } ?? "Record a take",
                                        ask: nil, steps: ["Ask you", "Record", "Transcribe"]), client)
        await board.step(job.id, 0)
        var details = [MCPQuestion.Detail("For", purpose?.title ?? "Just record")]
        if let named { details.append(MCPQuestion.Detail("Title", named)) }
        details.append(MCPQuestion.Detail("Stops", "When you press Stop, or \(client.displayName) asks"))
        let question = MCPQuestion(action: .record, client: client,
                                   title: "Record your screen for \(client.displayName)?",
                                   details: details, jobID: job.id)
        let answer = await permit(question, destination: "This Mac")
        guard answer.allowed else { return refused(answer) }
        do {
            let take = try await host.startRecording()
            if let named { try? take.setTitle(named) }
            if let purpose { try? TakePlan(purpose: purpose).write(for: take) }
            await board.update(job.id) { $0.takeFolder = take.folder }
            if let desk, let task = await desk.tasks.first(where: { $0.jobIDs.contains(job.id) }) {
                await desk.addTake(take, to: task.id)
            }
            await board.step(job.id, 1)
            return .done("Recording “\(named ?? take.name)”. Call stop_recording when the demo is done.",
                         ["take": .string(take.name), "task_id": .string(job.id.uuidString)])
        } catch {
            await board.fail(job.id, error.localizedDescription)
            throw Failure(error.localizedDescription)
        }
    }

    func stopRecording() async throws -> MCPToolResult {
        guard await host.isRecording() else {
            return .done("Nothing is recording.", ["recording": false])
        }
        let take = try await host.stopRecording()
        let job = await board.jobs.first {
            $0.agent == .producer && $0.state.isActive && Self.same($0.takeFolder, take.folder)
        }
        if let job { await board.step(job.id, 2) }
        let ready = await waitForTranscript(take)
        let transcript = try? Transcript.read(from: take.transcriptURL)
        let length = transcript.map { " (\(AgentReceipt.duration($0.duration)))" } ?? ""
        if let job { await board.finish(job.id, receipt: "Recorded “\(take.displayTitle())”\(length).", changes: []) }
        let text = ready
            ? "Saved “\(take.displayTitle())”\(length). The transcript is ready."
            : "Saved “\(take.displayTitle())”. Vision One is transcribing it on this Mac; get_take shows when it's ready."
        return .done(text, summary(take))
    }

    /// True once the take has a transcript or can't have one.
    func waitForTranscript(_ take: Take) async -> Bool {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            if fm.fileExists(atPath: take.transcriptURL.path) || fm.fileExists(atPath: take.transcriptFailedURL.path) {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    // MARK: Editing

    func cleanUp(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        let transcript = try await transcript(of: take)
        let job = await addJob(AgentJob(agent: .editor, title: "Clean up “\(take.displayTitle())”", take: take,
                                        steps: ["Find ums, repeats and long pauses", "Propose cuts"]), client)
        await board.step(job.id, 0)
        do {
            let added = try AutoClean.run(on: take, transcript: transcript)
            await board.step(job.id, 1)
            await board.finish(job.id, receipt: AgentReceipt.cuts(added), changes: added.map { AgentJob.Change.cut($0.id) })
        } catch {
            await board.fail(job.id, AgentRunner.message(for: error))
        }
        return describe(await board.job(job.id) ?? job)
    }

    func cutToLength(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        _ = try await transcript(of: take)
        let seconds = args["seconds"]?.doubleValue
        let ask = args["ask"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = (ask?.isEmpty == false) ? ask : nil
        guard seconds != nil || asked != nil else {
            throw Failure("Say how long it should be (seconds) or what to change (ask).")
        }
        var goal = asked.map(EditorAgent.Goal.parse) ?? EditorAgent.Goal()
        if let seconds { goal.targetSeconds = seconds }
        if let asked { goal.ask = asked }
        let finalGoal = goal
        let plan = await host.plan(for: take)
        let brief = await host.brief(for: plan)
        let title = finalGoal.targetSeconds.map { "Cut “\(take.displayTitle())” to \(AgentReceipt.duration($0))" }
        return await runAgent(client, take: take) { runner in
            await runner.edit(take, brief: brief, goal: finalGoal, energy: plan.energy, title: title)
        }
    }

    func cutPart(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        let transcript = try await transcript(of: take)
        let span: TimeSpan
        if let quote = args["quote"]?.stringValue, !quote.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let found = Self.find(quote, in: transcript.words) else {
                throw Failure("Couldn't find “\(quote)” in the transcript. Copy the words from read_transcript.")
            }
            span = found
        } else if let start = args["start"]?.doubleValue, let end = args["end"]?.doubleValue, end > start {
            span = TimeSpan(start: max(0, start), end: end)
        } else {
            throw Failure("Give a quote, or a start and end in seconds.")
        }
        var list = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
        let added = list.propose([Cut(span: span, reason: Cut.Reason.word, state: .proposed)])
        guard !added.isEmpty else {
            throw Failure("That part is already cut, proposed, or was turned down before.")
        }
        try list.write(to: take.editsURL)
        let job = await addJob(AgentJob(agent: .editor, title: "Cut a part of “\(take.displayTitle())”", take: take,
                                        steps: ["Propose the cut"]), client)
        await board.finish(job.id, receipt: AgentReceipt.cuts(added), changes: added.map { AgentJob.Change.cut($0.id) })
        return describe(await board.job(job.id) ?? job)
    }

    func makeClips(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        _ = try await transcript(of: take)
        let count = min(max(args["count"]?.intValue ?? 3, 1), 10)
        let format = args["format"]?.stringValue.flatMap(ClipFormat.init(rawValue:)) ?? .vertical
        let plan = await host.plan(for: take)
        let brief = await host.brief(for: plan)
        return await runAgent(client, take: take) { runner in
            await runner.clips(take, brief: brief, format: format, count: count)
        }
    }

    func draftPosts(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        _ = try await transcript(of: take)
        let launch = args["launch"]?.boolValue ?? false
        let product = args["product"]?.stringValue
        let plan = await host.plan(for: take)
        let brief = await host.brief(for: plan)
        return await runAgent(client, take: take) { runner in
            await runner.share(take, brief: brief, launch: launch, product: product)
        }
    }

    func keepChanges(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let id = try taskID(args)
        guard let job = await board.job(id) else { throw Failure("There's no task with that id. list_tasks shows them.") }
        guard job.state == .needsReview else {
            throw Failure(job.state == .done ? "Those changes are already kept." : "That task has nothing to keep: it's \(job.statusText).")
        }
        let question = MCPQuestion(action: .keep, client: client,
                                   title: "Keep \(client.displayName)'s changes to “\(job.take?.displayTitle() ?? job.title)”?",
                                   details: [MCPQuestion.Detail("Task", job.title),
                                             MCPQuestion.Detail("Changes", job.receipt ?? "Proposed edits")],
                                   jobID: job.id)
        // The task stays "needs your review" while the card asks.
        let answer = await permit(question, destination: "This Mac", onTask: false)
        guard answer.allowed else { return refused(answer) }
        try await board.keep(id)
        return .done("Kept. \(job.receipt ?? "")".trimmingCharacters(in: .whitespaces), jobJSON(await board.job(id) ?? job))
    }

    func undoChanges(_ args: [String: JSONValue]) async throws -> MCPToolResult {
        let id = try taskID(args)
        guard let job = await board.job(id) else { throw Failure("There's no task with that id. list_tasks shows them.") }
        guard job.state == .needsReview || job.state == .done, !job.changes.isEmpty else {
            throw Failure("That task has nothing to undo: it's \(job.statusText).")
        }
        try await board.undo(id)
        return .done("Undone. Its cuts and clips are out and its drafts deleted.", jobJSON(await board.job(id) ?? job))
    }

    // MARK: Files

    func writeCaptions(_ args: [String: JSONValue]) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        _ = try await transcript(of: take)
        let files = try take.writeCaptionFiles(settings: take.loadCaptionSettings(), to: take.folder)
        return .done("Wrote captions for the kept video.", ["files": .array(files.map { .string($0.path) })])
    }

    func exportVideo(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        let preset: ExportPreset
        if let raw = args["preset"]?.stringValue, !raw.isEmpty {
            guard let chosen = ExportPreset(rawValue: raw) else {
                throw Failure("Use one of: " + ExportPreset.allCases.map(\.rawValue).joined(separator: ", ") + ".")
            }
            preset = chosen
        } else {
            preset = ExportPreset.suggested(for: await host.plan(for: take).purpose).first ?? .hd1080
        }
        let waiting = (try? EditList.read(from: take.editsURL))?.cuts.filter { $0.state == .proposed }.count ?? 0
        let job = await addJob(AgentJob(agent: .editor, title: "Export \(preset.title) of “\(take.displayTitle())”",
                                        take: take, steps: ["Export \(preset.title)"]), client)
        await board.step(job.id, 0)
        let host = self.host
        let board = self.board
        let id = job.id
        Task {
            do {
                let url = try await host.export(take, preset: preset)
                await board.finish(id, receipt: "Exported \(url.path)", changes: [])
            } catch {
                await board.fail(id, error.localizedDescription)
            }
        }
        var result = describe(await settle(id, within: patience) ?? job)
        if waiting > 0, !result.isError {
            result.text += " \(waiting) proposed \(waiting == 1 ? "cut isn't" : "cuts aren't") in it; keep_changes first to include them."
        }
        return result
    }

    func shareVideo(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        let take = try resolveTake(args)
        guard let target = ShareTarget(network: args["to"]?.stringValue ?? "") else {
            throw Failure("Say where to share: whatsapp, linkedin, x or youtube.")
        }
        guard let picked = target.file(from: exports(of: take)) else {
            throw Failure("Export it first: export_video with preset \(target.preferred[0].rawValue).")
        }
        let text = target.text(in: SharePack.load(for: take))
        let job = await addJob(AgentJob(agent: .sharer, title: "Share “\(take.displayTitle())” to \(target.title)", take: take,
                                        steps: ["Ask you", "Open \(target.title)"]), client)
        await board.step(job.id, 0)
        let question = MCPQuestion(action: .share, client: client,
                                   title: "Share “\(take.displayTitle())” to \(target.title) for \(client.displayName)?",
                                   details: [MCPQuestion.Detail("Video", picked.url.lastPathComponent),
                                             MCPQuestion.Detail("To", target.title)],
                                   preview: text ?? "No words drafted yet. \(target.title) opens with just the video. draft_posts writes some.",
                                   jobID: job.id)
        let answer = await permit(question, destination: target.destination)
        guard answer.allowed else { return refused(answer) }
        await board.step(job.id, 1)
        do {
            try await host.share(picked.url, text: text, to: target)
        } catch {
            await board.fail(job.id, error.localizedDescription)
            throw Failure(error.localizedDescription)
        }
        let words = text == nil ? "" : " and the words copied"
        await board.finish(job.id, receipt: "Opened \(target.title) with the video\(words). The user posts it.", changes: [])
        return describe(await board.job(job.id) ?? job)
    }

    func renameTake(_ args: [String: JSONValue]) throws -> MCPToolResult {
        let take = try resolveTake(args)
        try take.setTitle(args["title"]?.stringValue ?? "")
        return .done("Now called “\(take.displayTitle())”.", ["take": .string(take.name)])
    }

    // MARK: Takes

    /// "latest", a folder name, a title, or part of one.
    func resolveTake(_ args: [String: JSONValue]) throws -> Take {
        let wanted = (args["take"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let takes = library.takes()
        guard let newest = takes.first else { throw Failure("There are no takes yet. Record one with start_recording.") }
        if wanted.isEmpty || wanted.lowercased() == "latest" { return newest }
        if let exact = takes.first(where: { $0.name == wanted }) { return exact }
        let folded = LibraryQuery.fold(wanted)
        let titled = takes.filter { LibraryQuery.fold($0.customTitle() ?? "") == folded }
        if titled.count == 1 { return titled[0] }
        let partial = titled.isEmpty
            ? takes.filter { LibraryQuery.fold($0.name).contains(folded) || LibraryQuery.fold($0.customTitle() ?? "").contains(folded) }
            : titled
        if partial.count == 1 { return partial[0] }
        if partial.isEmpty { throw Failure("No take matches “\(wanted)”. list_takes shows them.") }
        let names = partial.prefix(5).map(\.name).joined(separator: ", ")
        throw Failure("More than one take matches “\(wanted)”: \(names). Use the folder name.")
    }

    func listing(_ take: Take) -> TakeListing {
        let transcript = try? Transcript.read(from: take.transcriptURL)
        let edits = transcript.flatMap { try? EditList.load(from: take.editsURL, sourceDuration: $0.duration) }
        return TakeListing(take: take, title: take.displayTitle(), recordedAt: take.recordedAt(),
                           duration: transcript?.duration, isExported: !exports(of: take).isEmpty,
                           suggestedCuts: edits?.cuts.filter { $0.state == .proposed }.count ?? 0,
                           transcriptText: transcript?.text, purposeTitle: TakePlan.load(for: take)?.purpose.title)
    }

    func listingJSON(_ item: TakeListing) -> JSONValue {
        var object: [String: JSONValue] = [
            "take": .string(item.take.name),
            "title": .string(item.title),
            "exported": .bool(item.isExported),
            "proposedCuts": .number(Double(item.suggestedCuts)),
        ]
        if let date = item.recordedAt { object["recordedAt"] = .string(Self.iso(date)) }
        if let seconds = item.duration { object["seconds"] = .number(Self.rounded(seconds)) }
        if let purpose = item.purposeTitle { object["for"] = .string(purpose) }
        return .object(object)
    }

    func summary(_ take: Take) -> JSONValue {
        let transcript = try? Transcript.read(from: take.transcriptURL)
        let edits = transcript.flatMap { try? EditList.load(from: take.editsURL, sourceDuration: $0.duration) }
        let clips = (try? ClipList.read(from: take.clipsURL))?.clips ?? []
        var object: [String: JSONValue] = [
            "take": .string(take.name),
            "title": .string(take.displayTitle()),
            "folder": .string(take.folder.path),
            "transcript": .string(transcriptState(take)),
            "exports": .array(exports(of: take).sorted { $0.key.rawValue < $1.key.rawValue }.map { preset, url -> JSONValue in
                ["preset": .string(preset.rawValue), "file": .string(url.path)]
            }),
            "clips": .array(clips.map { clip -> JSONValue in
                ["title": .string(clip.title), "start": .number(Self.rounded(clip.start)), "end": .number(Self.rounded(clip.end)),
                 "format": .string(clip.format.rawValue), "state": .string(clip.state.rawValue)]
            }),
        ]
        if let date = take.recordedAt() { object["recordedAt"] = .string(Self.iso(date)) }
        if let plan = TakePlan.load(for: take) { object["for"] = .string(plan.purpose.title) }
        if let transcript { object["seconds"] = .number(Self.rounded(transcript.duration)) }
        if let edits {
            object["editedSeconds"] = .number(Self.rounded(edits.outputDuration))
            object["keptCuts"] = .number(Double(edits.cuts.filter { $0.state == .accepted }.count))
            object["proposedCuts"] = .number(Double(edits.cuts.filter { $0.state == .proposed }.count))
        }
        return .object(object)
    }

    func transcriptState(_ take: Take) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: take.transcriptURL.path) { return "ready" }
        if fm.fileExists(atPath: take.transcriptFailedURL.path) { return "none: nothing was said" }
        return "transcribing"
    }

    func exports(of take: Take) -> [ExportPreset: URL] {
        var found: [ExportPreset: URL] = [:]
        for preset in ExportPreset.allCases {
            let url = take.exportURL(for: preset)
            if FileManager.default.fileExists(atPath: url.path) { found[preset] = url }
        }
        return found
    }

    /// The transcript, waiting a little while Vision One is still making it.
    func transcript(of take: Take) async throws -> Transcript {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(patience)
        while true {
            if fm.fileExists(atPath: take.transcriptURL.path) { return try Transcript.read(from: take.transcriptURL) }
            if fm.fileExists(atPath: take.transcriptFailedURL.path) {
                throw Failure("Nothing was said in this take, so there are no words to edit by.")
            }
            if Date() >= deadline {
                throw Failure("The transcript isn't ready yet. Vision One is still transcribing; try again in a minute.")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Where a quote was said, matching words whatever their case and
    /// punctuation.
    static func find(_ quote: String, in words: [TranscriptWord]) -> TimeSpan? {
        let wanted = quote.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
        let spoken = words.indices.filter { !fold(words[$0].text).isEmpty }
        let said = spoken.map { fold(words[$0].text) }
        guard !wanted.isEmpty, said.count >= wanted.count else { return nil }
        for start in 0...(said.count - wanted.count) where Array(said[start..<(start + wanted.count)]) == wanted {
            return TimeSpan(start: words[spoken[start]].start, end: words[spoken[start + wanted.count - 1]].end)
        }
        return nil
    }

    static func fold(_ word: String) -> String {
        String(LibraryQuery.fold(word).filter { $0.isLetter || $0.isNumber })
    }

    // MARK: Tasks

    func taskID(_ args: [String: JSONValue]) throws -> UUID {
        guard let raw = args["task_id"]?.stringValue, let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            throw Failure("Give the task_id a tool returned. list_tasks shows them.")
        }
        return id
    }

    /// Adds a job marked with who asked for it, filed under its task.
    func addJob(_ job: AgentJob, _ client: MCPClient) async -> AgentJob {
        var job = job
        job.requestedBy = client.displayName
        let added = await board.add(job)
        if let desk, let taskID = await deskTask(for: job.take, title: job.title, client: client) {
            await desk.attach(jobID: added.id, to: taskID)
        }
        return added
    }

    /// The Desk task for a take: the one it's already in, or a new one
    /// tagged with the agent.
    func deskTask(for take: Take?, title: String, client: MCPClient) async -> UUID? {
        guard let desk else { return nil }
        if let take, let existing = await desk.tasks.first(where: { !$0.archived && $0.takeFolders.contains { Self.same($0, take.folder) } }) {
            return existing.id
        }
        let task = await desk.newTask(title: take.map { $0.displayTitle() } ?? title, takes: take.map { [$0] } ?? [])
        await desk.markRequested(task.id, by: client.displayName)
        return task.id
    }

    /// Starts an agent job and follows it for a while.
    func runAgent(_ client: MCPClient, take: Take,
                  _ work: @escaping @Sendable (AgentRunner) async -> Void) async -> MCPToolResult {
        let origin = AgentJobOrigin(requestedBy: client.displayName)
        var runner = await host.runner()
        if let desk, let taskID = await deskTask(for: take, title: take.displayTitle(), client: client) {
            runner.onJobAdded = { job in await desk.attach(jobID: job.id, to: taskID) }
        }
        let started = runner
        Task {
            await MCPJobContext.$origin.withValue(origin) {
                await work(started)
            }
        }
        guard let job = await settle(origin.jobID, within: patience) else {
            return .failed("The agent didn't start. Try again.")
        }
        return describe(job)
    }

    /// The job once it's finished or needs the user, or as it is when
    /// time runs out. Nil if it never appeared.
    func settle(_ id: UUID, within seconds: Double) async -> AgentJob? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let job = await board.job(id)
            if let job, !job.state.isActive { return job }
            if Date() >= deadline { return job }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func describe(_ job: AgentJob) -> MCPToolResult {
        let data = jobJSON(job)
        switch job.state {
        case .done:
            return .done(job.receipt ?? "Done.", data)
        case .needsReview:
            return .done((job.receipt ?? "Done.")
                + " The changes are dashed in Vision One until kept: call keep_changes with this task_id, or undo_changes to drop them.", data)
        case .needsApproval:
            return .done("Waiting for the user to approve in Vision One. Call wait_for_task with this task_id.", data)
        case .failed:
            return MCPToolResult(text: job.error ?? "It didn't finish.", data: data, isError: true)
        case .cancelled:
            return MCPToolResult(text: "Stopped: the user said no or stopped it in Vision One.", data: data, isError: true)
        case .undone:
            return .done("Undone.", data)
        default:
            return .done("Still working: \(job.statusText). Call wait_for_task with this task_id.", data)
        }
    }

    func jobJSON(_ job: AgentJob) -> JSONValue {
        var object: [String: JSONValue] = [
            "task_id": .string(job.id.uuidString),
            "title": .string(job.title),
            "agent": .string(job.agent.title),
            "state": .string(job.state.rawValue),
            "status": .string(job.statusText),
        ]
        if let take = job.take { object["take"] = .string(take.name) }
        if let by = job.requestedBy { object["requestedBy"] = .string(by) }
        if let receipt = job.receipt { object["receipt"] = .string(receipt) }
        if let error = job.error { object["error"] = .string(error) }
        if !job.steps.isEmpty {
            object["steps"] = .array(job.steps.map { step -> JSONValue in
                ["step": .string(step.title), "state": .string(step.state.rawValue)]
            })
        }
        return .object(object)
    }

    // MARK: Approvals

    /// Asks the user, unless they allowed this agent until quit. The
    /// task shows it's waiting while the card is up.
    /// Asks the user, unless they allowed this agent until quit. With a
    /// task, the question is a card on it as well as the floating card;
    /// whichever the user answers first counts and the other goes away.
    func permit(_ question: MCPQuestion, destination: String, onTask: Bool = true) async -> MCPAnswer {
        if await permissions.allows(question.client, question.action) { return MCPAnswer(.allowForSession) }
        let answer: MCPAnswer
        if onTask, let jobID = question.jobID {
            let floating = AnswerBox()
            let host = self.host
            let decision = await board.requestApproval(jobID: jobID,
                                                       approval: AgentJob.Approval(question, destination: destination)) {
                let reply = await host.ask(question)
                await floating.set(reply)
                return reply.decision
            }
            await host.dismiss(question.id)
            let note = await floating.answer?.note
            answer = MCPAnswer(decision, note: decision == .deny ? note : nil)
        } else {
            answer = await host.ask(question)
        }
        if answer.decision == .allowForSession { await permissions.allow(question.client, question.action) }
        return answer
    }

    func refused(_ answer: MCPAnswer) -> MCPToolResult {
        var text = "The user said no in Vision One."
        if let note = answer.note { text += " They said: “\(note)”" }
        return .failed(text)
    }

    // MARK: Formatting

    /// "1:05".
    // MARK: Autopilot demos

    func listDemos(_ args: [String: JSONValue]) async -> MCPToolResult {
        var demos = await host.demos()
        if let search = args["search"]?.stringValue?.trimmingCharacters(in: .whitespaces), !search.isEmpty {
            demos = demos.filter {
                $0.demo.name.localizedCaseInsensitiveContains(search)
                    || $0.demo.app.displayName.localizedCaseInsensitiveContains(search)
            }
        }
        let list: [JSONValue] = demos.map { file in
            var item: [String: JSONValue] = [
                "name": .string(file.demo.name),
                "app": .string(file.demo.app.displayName),
                "steps": .number(Double(file.demo.steps.count)),
                "about_seconds": .number(Self.rounded(file.demo.estimatedSeconds)),
                "rerecords_on_release": .bool(file.demo.rerecordOnRelease),
            ]
            if let repo = file.demo.repo { item["repo"] = .string(repo) }
            return .object(item)
        }
        let text = demos.isEmpty
            ? "No demos yet. The user makes them in Vision One (Autopilot), or adds .visionone/demos/*.json to a linked repo."
            : "\(demos.count) \(demos.count == 1 ? "demo" : "demos")."
        return .done(text, ["demos": .array(list)])
    }

    func rerecordDemo(_ args: [String: JSONValue], client: MCPClient) async throws -> MCPToolResult {
        guard let name = args["demo"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw Failure("Say which demo. list_demos shows them.")
        }
        let release = args["release"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        guard let id = await host.rerecordDemo(name, release: (release?.isEmpty == false) ? release : nil,
                                               requestedBy: client.displayName) else {
            let names = await host.demos().map(\.demo.name)
            throw Failure("There's no demo called “\(name)”."
                + (names.isEmpty ? "" : " Demos: " + names.joined(separator: ", ") + "."))
        }
        if let desk, let taskID = await deskTask(for: nil, title: "Re-record “\(name)”", client: client) {
            await desk.attach(jobID: id, to: taskID)
        }
        // A run takes a minute or more; answer quickly with the id.
        guard let job = await settle(id, within: min(patience, 5)) else {
            return .done("Autopilot is starting “\(name)”. Call wait_for_task to follow it.",
                         ["task_id": .string(id.uuidString), "state": "running"])
        }
        return describe(job)
    }

    /// The same folder, even when one path goes through /var and the other /private/var.
    static func same(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func rounded(_ seconds: Double) -> Double {
        (seconds * 100).rounded() / 100
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Holds the floating card's answer, note and all.
actor AnswerBox {
    private(set) var answer: MCPAnswer?
    func set(_ answer: MCPAnswer) { self.answer = answer }
}
