import AppKit
import VisionOneKit

/// Runs demos: opens the app, records its window, and clicks through the
/// steps while the pill shows what's happening. Each run is an Agent Desk
/// job (agent `.autopilot`) and leaves autopilot.json in its take.
///
/// Safety: only the demo's apps (never `AutopilotPolicy.alwaysBlocked`),
/// never password fields, the pill is up for the whole run, Esc stops,
/// and touching the mouse or keyboard pauses. Runs the person didn't start
/// here (a release, the MCP server, the GitHub Action) ask first, unless
/// the person already said these exact steps may run on their own.
@MainActor
final class AutopilotService: ObservableObject {
    static let shared = AutopilotService()

    /// The run in progress, updated step by step.
    @Published private(set) var running: AutopilotRun?
    @Published private(set) var isBusy = false
    @Published private(set) var startProblems: [String: String] = [:]
    private let injectedBoard: AgentJobBoard?
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibility: @MainActor () -> Bool
    private var board: AgentJobBoard { injectedBoard ?? AIServices.shared.jobs }
    /// Folders with demos besides Vision One's own (repo roots).
    @Published var linkedFolders: [URL] {
        didSet { UserDefaults.standard.set(linkedFolders.map(\.path), forKey: Self.linkedKey) }
    }
    @Published private(set) var state: AutopilotState

    let policy = AutopilotPolicy()
    private static let linkedKey = "autopilot.linkedFolders"

    private let guardian = AutopilotGuard()
    private let hands = InputPoster.shared
    private let pill = AutopilotPill.shared
    private var stopReason: StopReason?
    private var paused = false
    /// "checkout-demo@v1.4.0" tried this session, so a failed release run
    /// doesn't ask again every hour.
    private var tried: Set<String> = []

    init(board: AgentJobBoard? = nil,
         accessibilityTrusted: @escaping @MainActor () -> Bool = { AXReader.isTrusted },
         requestAccessibility: @escaping @MainActor () -> Bool = { AXReader.askForAccess() }) {
        injectedBoard = board
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibility = requestAccessibility
        linkedFolders = (UserDefaults.standard.stringArray(forKey: Self.linkedKey) ?? []).map { URL(fileURLWithPath: $0) }
        state = AutopilotState.load()
    }

    var library: DemoLibrary { .standard(linked: linkedFolders) }

    /// The last run of `demo`, read from its take.
    func lastRun(of demo: DemoScript) -> AutopilotRun? {
        state[demo].lastTakeFolder.flatMap { AutopilotRun.load(for: Take(folder: $0)) }
    }

    func startProblem(for demo: DemoScript) -> String? { startProblems[demo.slug] }

    // MARK: Starting

    /// The person pressed Run Autopilot.
    @discardableResult
    func run(_ file: DemoFile) -> UUID {
        start(file, release: nil, requestedBy: nil, requestID: nil, personIsHere: true)
    }

    /// For the MCP server and links: re-records the demo called `name`
    /// and returns its Agent Desk job id, or nil when there's no such demo.
    /// The job runs on; follow it on the job board.
    @discardableResult
    func rerecord(name: String, release: String? = nil, requestedBy: String? = nil) -> UUID? {
        rerecord(RerecordRequest(name: name, release: release, requestedBy: requestedBy))
    }

    @discardableResult
    func rerecord(_ request: RerecordRequest) -> UUID? {
        guard let file = library.find(request.name) else {
            try? RerecordStatus(id: request.id, demo: request.name, release: request.release, state: .unknownDemo,
                                receipt: "There's no demo called “\(request.name)”.").write()
            return nil
        }
        return start(file, release: request.release, requestedBy: request.requestedBy, requestID: request.id,
                     personIsHere: false)
    }

    /// A release came in for a demo that re-records on release.
    func rerecord(_ plan: RerecordPlan) {
        let key = "\(plan.demo.demo.slug)@\(plan.release)"
        guard !tried.contains(key) else { return }
        tried.insert(key)
        _ = start(plan.demo, release: plan.release, requestedBy: "release \(plan.release)", requestID: nil,
                  personIsHere: false)
    }

    /// Lets these exact steps run without asking (Re-record on release).
    func approve(_ demo: DemoScript) {
        state.approve(demo)
        saveState()
    }

    func setBaseline(_ newState: AutopilotState) {
        guard newState != state else { return }
        state = newState
        saveState()
    }

    private func start(_ file: DemoFile, release: String?, requestedBy: String?, requestID: UUID?,
                       personIsHere: Bool) -> UUID {
        let demo = file.demo
        let title = release.map { "Re-record “\(demo.name)” for \($0)" } ?? "Record “\(demo.name)”"
        var job = AgentJob(agent: .autopilot, title: title, ask: requestedBy.map { "From \($0)" },
                           steps: demo.steps.map { StepWords.line(for: $0) })
        job.requestedBy = requestedBy
        let board = self.board
        let ask = !personIsHere && !state.mayRunAlone(demo)
        Task {
            await board.add(job)
            await perform(demo, release: release, requestedBy: requestedBy, requestID: requestID,
                          jobID: job.id, ask: ask, unattended: !personIsHere)
        }
        return job.id
    }

    // MARK: A run

    private func perform(_ demo: DemoScript, release: String?, requestedBy: String?, requestID: UUID?,
                         jobID: UUID, ask: Bool, unattended: Bool) async {
        let board = self.board
        func status(_ s: RerecordStatus.State, _ receipt: String? = nil, take: Take? = nil) {
            guard let requestID else { return }
            try? RerecordStatus(id: requestID, demo: demo.name, release: release, state: s, receipt: receipt,
                                takeFolder: take?.folder.path).write()
        }
        func give(up reason: StopReason) async {
            startProblems[demo.slug] = reason.message
            await board.fail(jobID, reason.message)
            status(.stopped, reason.message)
        }

        // One run at a time; later ones wait their turn.
        while isBusy { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        isBusy = true
        defer { isBusy = false }
        startProblems[demo.slug] = nil

        if let problem = demo.problems(policy: policy).first {
            startProblems[demo.slug] = problem
            await board.fail(jobID, problem)
            status(.stopped, problem)
            return
        }
        if ask {
            status(.waiting)
            switch confirm(demo, release: release, requestedBy: requestedBy) {
            case .no:
                await board.cancel(jobID)
                status(.stopped, "You said not now.")
                return
            case .once:
                break
            case .always:
                approve(demo)
            }
        }
        guard accessibilityTrusted() || requestAccessibility() else {
            await give(up: .noAccess)
            return
        }
        status(.running)
        await board.update(jobID) { $0.state = .running }

        // Open the app and size its window.
        guard let app = await launch(demo) else {
            await give(up: .notFound(demo.app.displayName))
            return
        }
        let axApp = AXReader.app(app.processIdentifier)
        AXReader.wakeWebContent(axApp)
        guard let window = AXReader.window(of: axApp) else {
            await give(up: .notFound("a \(demo.app.displayName) window"))
            return
        }
        if let size = demo.window {
            AXReader.setSize(of: window, to: CGSize(width: size.width, height: size.height))
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // Count down with the guard armed, so Esc can still call it off.
        stopReason = nil
        paused = false
        hands.halted = false
        armGuard()
        pill.appName = demo.app.displayName
        pill.stepCount = demo.steps.count
        pill.stepNumber = 0
        pill.stepLine = ""
        pill.isLive = false
        pill.show(on: NSScreen.main)
        for n in stride(from: 3, through: 1, by: -1) where stopReason == nil {
            pill.mode = .countdown(n)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if let reason = stopReason {
            finishUI()
            await board.cancel(jobID)
            status(.stopped, reason.message)
            return
        }

        // Record just this window.
        let recorder = ScreenRecorder.shared
        let savedChoice = recorder.choice
        guard let windowID = await windowID(for: demo, near: AXReader.frame(of: window)) else {
            finishUI()
            await give(up: .recordingFailed("Vision One can't see the \(demo.app.displayName) window."))
            return
        }
        var choice = savedChoice
        choice.mode = .window
        choice.windowID = windowID
        // Your voice goes on afterwards, reading the script.
        choice.includeMicrophone = false
        choice.includeSystemSound = true
        recorder.choice = choice
        await recorder.start()
        guard case let .recording(startedAt) = recorder.phase else {
            recorder.choice = savedChoice
            finishUI()
            let why: String
            if case let .failed(message) = recorder.phase { why = message } else { why = "it didn't start." }
            await give(up: .recordingFailed(why))
            return
        }
        _ = app.activate()
        pill.isLive = true
        pill.mode = .driving
        let clock = { Date().timeIntervalSince(startedAt) }

        var run = AutopilotRun(demo: demo, release: release, requestedBy: requestedBy, startedAt: startedAt)
        running = run
        for (i, step) in demo.steps.enumerated() {
            if let reason = await checkpoint(clock) {
                run.stop(reason)
                break
            }
            run.begin(i, at: clock())
            running = run
            pill.stepNumber = i + 1
            pill.stepLine = StepWords.line(for: step)
            await board.step(jobID, i)

            switch await act(step, demo: demo, app: app) {
            case .done(let usedPosition):
                run.finish(i, at: clock(), usedPosition: usedPosition)
                running = run
                try? await Task.sleep(nanoseconds: UInt64(demo.pace.pauseAfterStep * 1_000_000_000))
            case .failed(let reason, let suggestion):
                // An Esc mid-step reads as Esc, not as a missing button.
                run.fail(i, at: clock(), reason: stopReason ?? reason, suggestion: stopReason == nil ? suggestion : nil)
            }
            if run.failedIndex != nil { break }
        }
        if run.finishedAt == nil { run.stop(stopReason ?? .stopped) }
        if run.finishedAll { run.stopped = nil }

        // Stop recording and keep what happened with the take.
        finishUI()
        await recorder.stop()
        recorder.choice = savedChoice
        running = nil
        let take = recorder.lastTake
        if let take {
            try? run.write(for: take)
            state.recorded(demo, release: run.finishedAll ? release : nil, take: take)
            saveState()
        }

        let finished = run
        let receipt = finished.receipt
        if finished.finishedAll {
            status(.recorded, receipt, take: take)
            await board.update(jobID) { job in
                for i in job.steps.indices { job.steps[i].state = .done }
                job.receipt = receipt
                // A release run waits in Needs you; one you watched is done.
                job.state = unattended ? .needsReview : .done
            }
        } else if finished.stopped?.byPerson == true {
            status(.stopped, receipt, take: take)
            await board.update(jobID) { job in
                Self.copy(finished, into: &job)
                job.receipt = receipt
                job.state = .cancelled
            }
        } else {
            status(.stopped, receipt, take: take)
            let hasFix = finished.failedIndex.map { finished.steps[$0].suggestion != nil } ?? false
            await board.update(jobID) { job in
                Self.copy(finished, into: &job)
                job.receipt = receipt
                job.error = hasFix ? nil : finished.stopped?.message
                job.state = hasFix ? .needsReview : .failed
            }
        }
    }

    // MARK: Steps

    private enum Outcome {
        case done(usedPosition: Bool)
        case failed(StopReason, UITarget?)
    }

    private func act(_ step: DemoStep, demo: DemoScript, app: NSRunningApplication) async -> Outcome {
        let axApp = AXReader.app(app.processIdentifier)
        switch step.action {
        case .open:
            guard let text = step.text, let url = Self.url(text) else { return .failed(.notFound(step.text ?? "it"), nil) }
            await open(url, in: demo)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return .done(usedPosition: false)
        case .wait where step.target == nil:
            try? await Task.sleep(nanoseconds: UInt64(max(step.seconds ?? 1, 0) * 1_000_000_000))
            return .done(usedPosition: false)
        case .press:
            guard let keys = step.keys, let combo = KeyCombo(keys) else { return .failed(.notFound(step.keys ?? "that key"), nil) }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if case let .stop(reason) = policy.check(step, in: demo, bundleID: front) { return .failed(reason, nil) }
            await hands.press(combo)
            return .done(usedPosition: false)
        default:
            break
        }

        // Find what the step acts on, waiting for it to appear.
        var point: CGPoint?
        var node: AXNode?
        var usedPosition = false
        if let target = step.target {
            if target.name == nil, target.identifier == nil, let seen = target.lastSeen,
               let window = AXReader.window(of: axApp), let frame = AXReader.frame(of: window) {
                // Nothing to name it by: the spot it was recorded at.
                point = CGPoint(x: frame.minX + seen.x * frame.width, y: frame.minY + seen.y * frame.height)
                usedPosition = true
            } else {
                switch await find(target, in: axApp) {
                case .found(let found): node = found
                case .missing(let suggestion): return .failed(.notFound(target.label), suggestion)
                }
            }
        }
        if step.action == .wait { return .done(usedPosition: false) }

        if var current = node {
            // Disabled for now (a form still loading): give it a moment.
            if !current.candidate.isEnabled, step.action == .click, let target = step.target {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if case .found(let again) = await find(target, in: axApp) { current = again }
            }
            let bundle = AXReader.bundleID(of: current.element)
            switch policy.check(step, in: demo, bundleID: bundle, element: current.candidate) {
            case .go: break
            case .wait: return .failed(.notFound("\(step.target?.label ?? "it") ready to press"), nil)
            case .stop(let reason): return .failed(reason, nil)
            }
            var frame = CGRect(x: current.candidate.x, y: current.candidate.y,
                               width: current.candidate.width, height: current.candidate.height)
            if let window = AXReader.window(of: axApp), let windowFrame = AXReader.frame(of: window),
               !windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                AXReader.scrollToVisible(current.element)
                try? await Task.sleep(nanoseconds: 400_000_000)
                frame = AXReader.frame(of: current.element) ?? frame
            }
            point = CGPoint(x: frame.midX, y: frame.midY)
            node = current
        }

        // Whatever is really under that spot must belong to an allowed app.
        if let point, let under = AXReader.element(at: point), let id = AXReader.bundleID(of: under),
           !demo.appsInPlay.contains(id) || policy.isAlwaysBlocked(id) {
            return .failed(policy.isAlwaysBlocked(id) ? .blockedApp(AutopilotPolicy.appName(id))
                                                       : .notAllowed(AutopilotPolicy.appName(id)), nil)
        }

        switch step.action {
        case .click:
            guard let point else { return .failed(.notFound("something to click"), nil) }
            await hands.glide(to: point, pace: demo.pace)
            guard !hands.halted else { return .failed(.stopped, nil) }
            await hands.click(at: point)
        case .point:
            guard let point else { return .failed(.notFound("something to point at"), nil) }
            await hands.glide(to: point, pace: demo.pace)
            try? await Task.sleep(nanoseconds: 600_000_000)
        case .type:
            if let point {
                await hands.glide(to: point, pace: demo.pace)
                guard !hands.halted else { return .failed(.stopped, nil) }
                await hands.click(at: point)
                if let node { AXReader.focus(node.element) }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Keys go to whatever is in front: check that app and the
            // field that really has focus, whatever the step said.
            let front = NSWorkspace.shared.frontmostApplication
            let focused = front.flatMap { AXReader.focused(in: AXReader.app($0.processIdentifier)) }
            if case let .stop(reason) = policy.check(step, in: demo, bundleID: front?.bundleIdentifier,
                                                     element: focused.flatMap { AXReader.candidate(for: $0) }) {
                return .failed(reason, nil)
            }
            await hands.type(step.text ?? "", pace: demo.pace)
        case .scroll:
            if let point { await hands.glide(to: point, pace: demo.pace) }
            await hands.scroll(step.direction ?? .down, lines: step.amount ?? 5)
        case .open, .press, .wait:
            break
        }
        if hands.halted, let reason = stopReason { return .failed(reason, nil) }
        return .done(usedPosition: usedPosition)
    }

    private enum Lookup {
        case found(AXNode)
        case missing(UITarget?)
    }

    /// Looks for `target` until it shows up or `policy.findTimeout` passes,
    /// like Playwright's auto-wait. When it never does, offers a likely
    /// replacement.
    private func find(_ target: UITarget, in axApp: AXUIElement) async -> Lookup {
        let deadline = Date().addingTimeInterval(policy.findTimeout)
        var seen: [AXNode] = []
        var area = CaptureRect(x: 0, y: 0, width: 1, height: 1)
        repeat {
            if stopReason != nil { break }
            if let window = AXReader.window(of: axApp) {
                seen = AXReader.read(window)
                if let f = AXReader.frame(of: window) {
                    area = CaptureRect(x: f.minX, y: f.minY, width: f.width, height: f.height)
                }
                let candidates = seen.map(\.candidate)
                if let match = TargetMatcher.find(target, in: candidates),
                   let found = seen.first(where: { $0.candidate == match }) {
                    return .found(found)
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < deadline
        return .missing(TargetMatcher.suggestion(for: target, in: seen.map(\.candidate), window: area))
    }

    /// Waits out a pause, then says whether to stop.
    private func checkpoint(_ clock: () -> Double) async -> StopReason? {
        while paused, stopReason == nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if let stopReason { return stopReason }
        if clock() > policy.maxRunSeconds { return .tooLong }
        return nil
    }

    // MARK: Apps and windows

    private func launch(_ demo: DemoScript) async -> NSRunningApplication? {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: demo.app.bundleID) else { return nil }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let open = demo.app.open, let url = Self.url(open) {
            _ = try? await workspace.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            _ = try? await workspace.openApplication(at: appURL, configuration: config)
        }
        for _ in 0..<40 {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: demo.app.bundleID).first,
               AXReader.window(of: AXReader.app(app.processIdentifier)) != nil {
                _ = app.activate()
                return app
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func open(_ url: URL, in demo: DemoScript) async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: demo.app.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    /// A web address, or a file path.
    static func url(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://" + trimmed)
    }

    /// The ScreenCaptureKit window for the demo's app closest in size to
    /// the window Autopilot is driving.
    private func windowID(for demo: DemoScript, near frame: CGRect?) async -> UInt32? {
        let windows = await ScreenRecorder.shared.pickableWindows().filter { $0.bundleID == demo.app.bundleID }
        guard let frame else { return windows.first?.id }
        return windows.min { a, b in
            abs(a.width - frame.width) + abs(a.height - frame.height) < abs(b.width - frame.width) + abs(b.height - frame.height)
        }?.id
    }

    // MARK: Guard and pill

    private func armGuard() {
        guardian.onEscape = { [weak self] in self?.stop(.escape) }
        guardian.onTouch = { [weak self] in
            guard let self, self.policy.pauseOnTouch, !self.paused, self.stopReason == nil, self.pill.mode == .driving else { return }
            self.paused = true
            self.hands.halted = true
            self.pill.mode = .paused
        }
        pill.onStop = { [weak self] in self?.stop(.stopped) }
        pill.onResume = { [weak self] in
            guard let self else { return }
            self.paused = false
            self.hands.halted = false
            self.pill.mode = .driving
        }
        guardian.arm()
    }

    /// Stops the run in progress, if any.
    func stop(_ reason: StopReason = .stopped) {
        guard stopReason == nil else { return }
        stopReason = reason
        paused = false
        hands.halted = true
    }

    private func finishUI() {
        guardian.disarm()
        pill.hide()
        pill.isLive = false
    }

    // MARK: Asking

    private enum Consent { case no, once, always }

    private func confirm(_ demo: DemoScript, release: String?, requestedBy: String?) -> Consent {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Let Autopilot record “\(demo.name)”?"
        var info = "Autopilot will open \(demo.app.displayName) and click through \(demo.steps.count) "
            + "\(demo.steps.count == 1 ? "step" : "steps") while Vision One records the window."
        if let release { info += " It's for \(release)." }
        if let requestedBy { info += " Asked by \(requestedBy)." }
        info += " Press Esc to stop it, or move the mouse to pause it."
        alert.informativeText = info
        alert.addButton(withTitle: "Record It")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Record, and Don't Ask Again for This Demo")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .once
        case .alertThirdButtonReturn: return .always
        default: return .no
        }
    }

    // MARK: Saving

    private func saveState() {
        try? state.write()
    }

    private nonisolated static func copy(_ run: AutopilotRun, into job: inout AgentJob) {
        for (i, result) in run.steps.enumerated() where job.steps.indices.contains(i) {
            switch result.state {
            case .done: job.steps[i].state = .done
            case .failed: job.steps[i].state = .failed
            case .skipped, .pending: job.steps[i].state = .skipped
            case .running: job.steps[i].state = .failed
            }
        }
    }
}
