import XCTest
@testable import VisionOneKit

final class AutopilotTests: XCTestCase {
    func checkoutDemo() -> DemoScript {
        DemoScript(name: "Checkout demo",
                   app: DemoApp(bundleID: "com.apple.Safari", open: "https://rankride.co.za/ranks"),
                   steps: [
                       DemoStep(.click, target: UITarget(role: "AXLink", name: "Bree St rank"), say: "Pick your rank."),
                       DemoStep(.point, target: UITarget(name: "Queue count")),
                       DemoStep(.click, target: UITarget(role: "AXButton", name: "Pay with SnapScan",
                                                         lastSeen: UnitPoint(x: 0.5, y: 0.8)),
                                say: "Pay and you're on your way."),
                   ],
                   repo: "VenusOne-Lee/rankride")
    }

    // MARK: Demo file

    func testDemoRoundTripsThroughJSONWithDoKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let demo = checkoutDemo()
        try demo.write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#""do" : "click""#))
        XCTAssertEqual(try DemoScript.load(from: url), demo)
    }

    func testHandWrittenDemoFillsDefaults() throws {
        let json = #"{"name":"Sign up","app":{"bundleID":"com.apple.Safari"},"steps":[{"do":"wait","seconds":2}]}"#
        let demo = try JSONDecoder().decode(DemoScript.self, from: Data(json.utf8))
        XCTAssertEqual(demo.pace, .normal)
        XCTAssertEqual(demo.allowedApps, [])
        XCTAssertTrue(demo.rerecordOnRelease)
        XCTAssertEqual(demo.steps.first?.seconds, 2)
    }

    func testScriptJoinsSayLinesAndSlugIsFileSafe() {
        let demo = checkoutDemo()
        XCTAssertEqual(demo.script, "Pick your rank. Pay and you're on your way.")
        XCTAssertEqual(demo.slug, "checkout-demo")
        XCTAssertEqual(DemoScript.slug("RankRide: Pay → Receipt!"), "rankride-pay-receipt")
    }

    func testProblemsNameBlockedAppsAndIncompleteSteps() {
        var demo = checkoutDemo()
        XCTAssertEqual(demo.problems(), [])
        demo.allowedApps = ["com.apple.Terminal"]
        demo.steps.append(DemoStep(.press, keys: "cmd+banana"))
        let problems = demo.problems()
        XCTAssertTrue(problems.contains("Autopilot never acts in Terminal."))
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 4:") })
    }

    // MARK: Plain words

    func testParsesPlainLines() throws {
        let steps = try StepWords.parse("""
        # Checkout
        Open https://rankride.co.za/ranks
        Click the "Bree St rank" link
        Say "Pick your rank."
        Point at "Queue count"
        Type "Thabo" into "Name"
        Press cmd+return
        Scroll down 5
        Wait 1.5s
        Wait for "Receipt"
        Click #pay-button
        """)
        XCTAssertEqual(steps.map(\.action), [.open, .click, .point, .type, .press, .scroll, .wait, .wait, .click])
        XCTAssertEqual(steps[0].text, "https://rankride.co.za/ranks")
        XCTAssertEqual(steps[1].target, UITarget(role: "AXLink", name: "Bree St rank"))
        XCTAssertEqual(steps[1].say, "Pick your rank.")
        XCTAssertEqual(steps[3].text, "Thabo")
        XCTAssertEqual(steps[3].target?.name, "Name")
        XCTAssertEqual(steps[4].keys, "cmd+return")
        XCTAssertEqual(steps[5].direction, .down)
        XCTAssertEqual(steps[5].amount, 5)
        XCTAssertEqual(steps[6].seconds, 1.5)
        XCTAssertEqual(steps[7].target?.name, "Receipt")
        XCTAssertEqual(steps[8].target?.identifier, "pay-button")
    }

    func testTypedTextWithIntoInsideQuotesHasNoTarget() throws {
        let step = try XCTUnwrap(StepWords.parseLine(#"Type "walk into town""#))
        XCTAssertEqual(step.text, "walk into town")
        XCTAssertNil(step.target)
    }

    func testUnknownLineSaysWhichLine() {
        XCTAssertThrowsError(try StepWords.parse("Click \"A\"\nDance wildly")) { error in
            XCTAssertEqual(error as? StepWords.ParseError, StepWords.ParseError(line: 2, text: "Dance wildly"))
        }
    }

    func testLinesRoundTrip() throws {
        let demo = checkoutDemo()
        let text = StepWords.text(for: demo.steps)
        let again = try StepWords.parse(text)
        XCTAssertEqual(again.map { StepWords.line(for: $0) }, demo.steps.map { StepWords.line(for: $0) })
        XCTAssertEqual(again.map(\.say), demo.steps.map(\.say))
        XCTAssertTrue(text.contains(#"Click the "Pay with SnapScan" button"#))
    }

    func testKeyCombos() throws {
        let k = try XCTUnwrap(KeyCombo("cmd+shift+k"))
        XCTAssertEqual(k.modifiers, [.command, .shift])
        XCTAssertEqual(k.keyCode, 40)
        XCTAssertEqual(k.display, "⇧⌘K")
        XCTAssertEqual(KeyCombo("⌘Return")?.keyCode, 36)
        XCTAssertEqual(KeyCombo("f5")?.keyCode, 96)
        XCTAssertNil(KeyCombo("hyper+k"))
        XCTAssertEqual(KeyCombo.text(keyCode: 36, modifiers: [.command]), "cmd+return")
        XCTAssertEqual(KeyCombo.text(keyCode: 40, modifiers: [.command, .shift]), "shift+cmd+k")
        XCTAssertEqual(KeyCombo(KeyCombo.text(keyCode: 40, modifiers: [.command, .shift])!)?.modifiers, [.command, .shift])
    }

    // MARK: Safety

    func testPolicyOnlyAllowsTheDemosApps() {
        let policy = AutopilotPolicy()
        let demo = checkoutDemo()
        let click = demo.steps[0]
        XCTAssertEqual(policy.check(click, in: demo, bundleID: "com.apple.Safari"), .go)
        XCTAssertEqual(policy.check(click, in: demo, bundleID: "com.apple.mail"), .stop(.notAllowed("mail")))
        XCTAssertEqual(policy.check(click, in: demo, bundleID: "com.apple.Terminal"), .stop(.blockedApp("Terminal")))
        XCTAssertEqual(policy.check(click, in: demo, bundleID: nil), .stop(.unknownApp))
    }

    func testAlwaysBlockedWinsEvenWhenTheDemoAllowsIt() {
        var demo = checkoutDemo()
        demo.allowedApps = ["com.apple.systempreferences", "za.co.versionone.visionone"]
        let policy = AutopilotPolicy()
        XCTAssertEqual(policy.check(demo.steps[0], in: demo, bundleID: "com.apple.systempreferences"),
                       .stop(.blockedApp("System Settings")))
        XCTAssertEqual(policy.check(demo.steps[0], in: demo, bundleID: "za.co.versionone.visionone"),
                       .stop(.blockedApp("Vision One")))
    }

    func testNeverTypesIntoPasswordFieldsAndWaitsForDisabledButtons() {
        let demo = checkoutDemo()
        let policy = AutopilotPolicy()
        let password = UICandidate(role: "AXSecureTextField", name: "Password", x: 0, y: 0, width: 100, height: 20)
        XCTAssertTrue(password.isSecure)
        XCTAssertEqual(policy.check(DemoStep(.type, target: UITarget(name: "Password"), text: "hunter2"),
                                    in: demo, bundleID: "com.apple.Safari", element: password), .stop(.passwordField))
        let disabled = UICandidate(role: "AXButton", name: "Pay", x: 0, y: 0, width: 80, height: 30, isEnabled: false)
        XCTAssertEqual(policy.check(demo.steps[2], in: demo, bundleID: "com.apple.Safari", element: disabled), .wait)
    }

    // MARK: Finding things

    let window = CaptureRect(x: 0, y: 0, width: 1000, height: 800)

    func screen() -> [UICandidate] {
        [
            UICandidate(role: "AXLink", name: "Bree St rank", x: 100, y: 100, width: 200, height: 40),
            UICandidate(role: "AXLink", name: "Bloem rank", x: 100, y: 160, width: 200, height: 40),
            UICandidate(role: "AXStaticText", name: "Queue count", x: 600, y: 100, width: 100, height: 20),
            UICandidate(role: "AXButton", name: "Pay now", identifier: "pay", x: 450, y: 620, width: 100, height: 40),
            UICandidate(role: "AXButton", name: "Cancel", x: 100, y: 700, width: 100, height: 40),
        ]
    }

    func testFindsByNameAndRoleIgnoringCaseAndKindChanges() {
        let found = TargetMatcher.find(UITarget(role: "AXLink", name: "bree st RANK"), in: screen())
        XCTAssertEqual(found?.name, "Bree St rank")
        // The link became a button: same family, still found.
        XCTAssertEqual(TargetMatcher.find(UITarget(role: "AXButton", name: "Bloem rank"), in: screen())?.name, "Bloem rank")
        XCTAssertEqual(TargetMatcher.find(UITarget(name: "Pay"), in: screen())?.name, "Pay now")
        XCTAssertEqual(TargetMatcher.find(UITarget(identifier: "pay"), in: screen())?.name, "Pay now")
        XCTAssertNil(TargetMatcher.find(UITarget(role: "AXButton", name: "Pay with SnapScan"), in: screen()))
    }

    func testIndexPicksAmongTwinsInReadingOrder() {
        let twins = [
            UICandidate(role: "AXButton", name: "Edit", x: 10, y: 300, width: 40, height: 20),
            UICandidate(role: "AXButton", name: "Edit", x: 10, y: 100, width: 40, height: 20),
        ]
        XCTAssertEqual(TargetMatcher.find(UITarget(role: "AXButton", name: "Edit"), in: twins)?.y, 100)
        XCTAssertEqual(TargetMatcher.find(UITarget(role: "AXButton", name: "Edit", index: 1), in: twins)?.y, 300)
    }

    func testSuggestsTheRenamedButtonInTheSameSpot() throws {
        let gone = checkoutDemo().steps[2].target!
        let fix = try XCTUnwrap(TargetMatcher.suggestion(for: gone, in: screen(), window: window))
        XCTAssertEqual(fix.name, "Pay now")
        XCTAssertEqual(fix.identifier, "pay")
    }

    func testNoSuggestionWhenNothingIsClose() {
        let gone = UITarget(role: "AXButton", name: "Export to TikTok", lastSeen: UnitPoint(x: 0.95, y: 0.05))
        XCTAssertNil(TargetMatcher.suggestion(for: gone, in: screen(), window: window))
    }

    func testRecordedClickBecomesANamedTarget() {
        let all = screen()
        let target = TargetMatcher.target(for: all[0], among: all, window: window)
        XCTAssertEqual(target.name, "Bree St rank")
        XCTAssertEqual(target.role, "AXLink")
        XCTAssertEqual(target.lastSeen, UnitPoint(x: 0.2, y: 0.15))
        XCTAssertNil(target.index)
    }

    // MARK: Cursor

    func testCursorGlideEasesAndEndsOnTarget() {
        let path = CursorPath(from: .init(x: 0, y: 0), to: .init(x: 700, y: 0), speed: 1400)
        XCTAssertEqual(path.duration, 0.5, accuracy: 0.001)
        let frames = path.frames(fps: 60)
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.last, .init(x: 700, y: 0))
        // Slow start: the first frame covers far less than an even share.
        XCTAssertLessThan(frames[0].x, 700.0 / 30)
        // Short and long trips are clamped.
        XCTAssertEqual(CursorPath(from: .init(x: 0, y: 0), to: .init(x: 10, y: 0), speed: 1400).duration, 0.25)
        XCTAssertEqual(CursorPath(from: .init(x: 0, y: 0), to: .init(x: 9000, y: 0), speed: 1400).duration, 1.2)
        XCTAssertEqual(CursorPath(from: .init(x: 5, y: 5), to: .init(x: 5, y: 5), speed: 1400).frames(), [.init(x: 5, y: 5)])
    }

    // MARK: Runs

    func testRunReceiptAndFailureSkipsTheRest() {
        var demo = checkoutDemo()
        demo.steps.append(DemoStep(.wait, seconds: 1))
        var run = AutopilotRun(demo: demo, release: "v1.4.0")
        run.begin(0, at: 0.5); run.finish(0, at: 2)
        run.begin(1, at: 2.5); run.finish(1, at: 4)
        run.begin(2, at: 4.5)
        run.fail(2, at: 12.4, reason: .notFound("“Pay with SnapScan” button"),
                 suggestion: UITarget(role: "AXButton", name: "Pay now"))
        XCTAssertEqual(run.steps.map(\.state), [.done, .done, .failed, .skipped])
        XCTAssertEqual(run.receipt, "Recorded 2 of 4 steps in 0:12. Step 3: It couldn't find “Pay with SnapScan” button.")
        XCTAssertEqual(run.markers.map { $0.start }, [0.5, 2.5, 4.5])
        XCTAssertEqual(run.steps[2].suggestion?.name, "Pay now")
    }

    func testFinishedRunAndVoiceReuse() {
        let demo = checkoutDemo()
        var run = AutopilotRun(demo: demo)
        for i in demo.steps.indices { run.begin(i, at: Double(i)); run.finish(i, at: Double(i) + 0.8) }
        XCTAssertTrue(run.finishedAll)
        XCTAssertEqual(run.receipt, "Recorded all 3 steps in 0:02.")
        XCTAssertTrue(run.voiceFits(demo))
        var changed = demo
        changed.steps[0].say = "Choose a rank."
        XCTAssertFalse(run.voiceFits(changed))
    }

    func testFingerprintChangesWithStepsNotScript() {
        let demo = checkoutDemo()
        var reworded = demo
        reworded.steps[0].say = "Something else."
        XCTAssertEqual(DemoFingerprint.of(demo), DemoFingerprint.of(reworded))
        var moved = demo
        moved.steps.swapAt(0, 1)
        XCTAssertNotEqual(DemoFingerprint.of(demo), DemoFingerprint.of(moved))
    }

    // MARK: Library and releases

    func testLibraryFindsDemosInItsFolderAndLinkedRepos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let own = root.appendingPathComponent("Demos")
        let repo = root.appendingPathComponent("rankride")
        try checkoutDemo().write(to: own.appendingPathComponent("checkout-demo.json"))
        try DemoScript(name: "Driver sign-up", app: DemoApp(bundleID: "com.apple.Safari"),
                       steps: [DemoStep(.wait)]).write(to: repo.appendingPathComponent(".visionone/demos/signup.json"))
        try Data("not json".utf8).write(to: own.appendingPathComponent("broken.json"))

        let library = DemoLibrary(folder: own, linked: [repo])
        XCTAssertEqual(library.all().map(\.demo.name), ["Checkout demo", "Driver sign-up"])
        XCTAssertEqual(library.find("CHECKOUT demo")?.demo.name, "Checkout demo")
        XCTAssertEqual(library.find("signup")?.demo.name, "Driver sign-up")
        XCTAssertEqual(library.newURL(for: "Checkout demo").lastPathComponent, "checkout-demo-2.json")
    }

    func testReleasesDecodeAndOnlyNewPublishedOnesAreDue() throws {
        let json = #"{"tag_name":"v1.4.0","name":"1.4","draft":false,"prerelease":false,"published_at":"2026-10-27T12:00:00Z","html_url":"https://github.com/VenusOne-Lee/rankride/releases/tag/v1.4.0"}"#
        let release = try GitHubRelease.decode(Data(json.utf8))
        XCTAssertEqual(release.tagName, "v1.4.0")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(GitHubRelease.latestURL(for: "VenusOne-Lee/rankride")?.absoluteString,
                       "https://api.github.com/repos/VenusOne-Lee/rankride/releases/latest")
        XCTAssertNil(GitHubRelease.latestURL(for: "not a repo"))

        let file = DemoFile(url: URL(fileURLWithPath: "/tmp/checkout.json"), demo: checkoutDemo())
        let latest = ["VenusOne-Lee/rankride": release]
        XCTAssertEqual(ReleaseWatch.repos(in: [file]), ["VenusOne-Lee/rankride"])

        // Never recorded: the release becomes the starting point, not a run.
        var state = AutopilotState()
        XCTAssertEqual(ReleaseWatch.due([file], latest: latest, state: state), [])
        state = ReleaseWatch.baseline([file], latest: latest, state: state)
        XCTAssertEqual(state[file.demo].lastRelease, "v1.4.0")
        XCTAssertEqual(ReleaseWatch.due([file], latest: latest, state: state), [])

        // Recorded for v1.3.0: due, and needs a yes until approved.
        state[file.demo].lastRelease = "v1.3.0"
        let plan = try XCTUnwrap(ReleaseWatch.due([file], latest: latest, state: state).first)
        XCTAssertEqual(plan.release, "v1.4.0")
        XCTAssertTrue(plan.needsApproval)
        state.approve(file.demo)
        XCTAssertEqual(ReleaseWatch.due([file], latest: latest, state: state).first?.needsApproval, false)

        // Drafts and prereleases never trigger a run.
        var pre = release
        pre.prerelease = true
        XCTAssertEqual(ReleaseWatch.due([file], latest: ["VenusOne-Lee/rankride": pre], state: state), [])
    }

    func testRerecordLinkRoundTrips() throws {
        let request = RerecordRequest(name: "Checkout demo", release: "v1.4.0", requestedBy: "GitHub")
        let again = try XCTUnwrap(RerecordRequest(url: request.url))
        XCTAssertEqual(again, request)
        XCTAssertNil(RerecordRequest(url: URL(string: "visionone://demo/rerecord")!))
        XCTAssertNil(RerecordRequest(url: URL(string: "https://example.com/demo/rerecord?name=x")!))
    }

    func testStatusFileRoundTrips() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let status = RerecordStatus(id: UUID(), demo: "Checkout demo", release: "v1.4.0", state: .recorded,
                                    receipt: "Recorded all 8 steps.", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try status.write(in: support)
        XCTAssertEqual(RerecordStatus.load(status.id, in: support), status)
        XCTAssertTrue(status.isFinal)
    }

    func testAutopilotJobsReadAsAutopilot() {
        let job = AgentJob(agent: .autopilot, title: "Re-record “Checkout demo” for v1.4.0", steps: ["Open Safari"])
        XCTAssertEqual(job.statusLine, "Autopilot · waiting to start")
    }
}
