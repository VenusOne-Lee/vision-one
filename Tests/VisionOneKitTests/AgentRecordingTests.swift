import XCTest
@testable import VisionOneKit

final class AgentRecordingTests: XCTestCase {
    // MARK: Who made an event

    func testOriginTellsPersonAgentAndVisionOneApart() {
        XCTAssertEqual(InputOrigin.of(sourcePID: 0, userData: 0, ownPID: 500), .person)
        XCTAssertEqual(InputOrigin.of(sourcePID: 812, userData: 0, ownPID: 500), .agent(pid: 812))
        XCTAssertEqual(InputOrigin.of(sourcePID: 500, userData: 0, ownPID: 500), .visionOne)
        XCTAssertEqual(InputOrigin.of(sourcePID: 812, userData: InputOrigin.autopilotTag, ownPID: 500), .visionOne,
                       "Autopilot's tagged events never count as an outside agent")
        XCTAssertTrue(InputOrigin.agent(pid: 1).isAgent)
        XCTAssertFalse(InputOrigin.person.isAgent)
    }

    func testKnownAgentApps() {
        XCTAssertEqual(AgentApps.match(bundleID: "com.anthropic.claudefordesktop", processName: nil), "Claude")
        XCTAssertEqual(AgentApps.match(bundleID: "com.openai.chat", processName: "ChatGPT"), "ChatGPT")
        XCTAssertEqual(AgentApps.match(bundleID: nil, processName: "cliclick"), "Computer use")
        XCTAssertNil(AgentApps.match(bundleID: "com.apple.Safari", processName: "Safari"))
        XCTAssertNil(AgentApps.match(bundleID: nil, processName: nil))
    }

    func testTakeoverNeedsAFewEventsThenStaysQuiet() {
        var detector = AgentTakeoverDetector(eventsNeeded: 3, within: 5, quietAfterOffer: 600)
        XCTAssertFalse(detector.see(pid: 9, at: 0))
        XCTAssertFalse(detector.see(pid: 9, at: 10), "too far apart")
        XCTAssertFalse(detector.see(pid: 9, at: 11))
        XCTAssertTrue(detector.see(pid: 9, at: 12))
        XCTAssertFalse(detector.see(pid: 9, at: 13))
        XCTAssertFalse(detector.see(pid: 9, at: 14))
        XCTAssertFalse(detector.see(pid: 9, at: 15), "quiet after an offer")
        XCTAssertFalse(detector.see(pid: 9, at: 700))
        XCTAssertFalse(detector.see(pid: 9, at: 701))
        XCTAssertTrue(detector.see(pid: 9, at: 702))
    }

    // MARK: Grouping input into actions

    func testClicksDoubleClicksRightClicksAndDrags() {
        var recorder = AgentActionRecorder()
        recorder.add(AgentInputEvent(.mouseDown(.left, clickCount: 1), t: 1, x: 100, y: 50, app: "Safari"))
        recorder.add(AgentInputEvent(.mouseUp(.left), t: 1.05, x: 100, y: 50))
        recorder.add(AgentInputEvent(.mouseDown(.left, clickCount: 1), t: 3, x: 200, y: 80))
        recorder.add(AgentInputEvent(.mouseUp(.left), t: 3.05, x: 200, y: 80))
        recorder.add(AgentInputEvent(.mouseDown(.left, clickCount: 2), t: 3.2, x: 201, y: 80))
        recorder.add(AgentInputEvent(.mouseUp(.left), t: 3.25, x: 201, y: 80))
        recorder.add(AgentInputEvent(.mouseDown(.right, clickCount: 1), t: 5, x: 10, y: 10))
        recorder.add(AgentInputEvent(.mouseUp(.right), t: 5.05, x: 10, y: 10))
        recorder.add(AgentInputEvent(.mouseDown(.left, clickCount: 1), t: 7, x: 10, y: 10))
        recorder.add(AgentInputEvent(.mouseUp(.left), t: 7.6, x: 300, y: 10))
        let actions = recorder.finish()
        XCTAssertEqual(actions.map(\.kind), [.click, .doubleClick, .rightClick, .drag])
        XCTAssertEqual(actions[0].app, "Safari")
        XCTAssertEqual(actions[0].x, 100)
        XCTAssertEqual(actions[0].line, "Clicked in Safari")
        XCTAssertEqual(actions[3].end, 7.6)
    }

    func testTypingIsGroupedAndBackspaceFixesIt() {
        var recorder = AgentActionRecorder()
        for (i, c) in "helo".enumerated() {
            recorder.add(AgentInputEvent(.key(characters: String(c), bare: String(c), keyCode: 0, modifiers: []),
                                         t: 1 + Double(i) * 0.1))
        }
        recorder.add(AgentInputEvent(.key(characters: "\u{7F}", bare: "\u{7F}", keyCode: 51, modifiers: []), t: 1.5))
        recorder.add(AgentInputEvent(.key(characters: "lo", bare: "lo", keyCode: 0, modifiers: []), t: 1.6))
        recorder.add(AgentInputEvent(.key(characters: "\r", bare: "\r", keyCode: 36, modifiers: []), t: 2))
        recorder.add(AgentInputEvent(.key(characters: "c", bare: "c", keyCode: 8, modifiers: [.command]), t: 3))
        recorder.add(AgentInputEvent(.key(characters: "T", bare: "t", keyCode: 17, modifiers: [.command, .shift]), t: 4))
        let actions = recorder.finish()
        XCTAssertEqual(actions.map(\.kind), [.type, .key, .key, .key])
        XCTAssertEqual(actions[0].text, "hello")
        XCTAssertEqual(actions[0].line, "Typed “hello”")
        XCTAssertEqual(actions[1].text, "Return")
        XCTAssertEqual(actions[2].text, "⌘C")
        XCTAssertEqual(actions[3].line, "Pressed ⇧⌘T")
    }

    func testPasswordsAndSecretsAreNeverKept() {
        var recorder = AgentActionRecorder()
        recorder.add(AgentInputEvent(.key(characters: "hunter22", bare: "hunter22", keyCode: 0, modifiers: []),
                                     t: 1, secure: true))
        recorder.add(AgentInputEvent(.mouseDown(.left, clickCount: 1), t: 2))
        recorder.add(AgentInputEvent(.mouseUp(.left), t: 2.1))
        let key = "sk-ant-api03-" + String(repeating: "a1B2", count: 8)
        recorder.add(AgentInputEvent(.key(characters: "key: \(key)", bare: "", keyCode: 0, modifiers: []), t: 3))
        let actions = recorder.finish()
        XCTAssertEqual(actions.first?.kind, .type)
        XCTAssertTrue(actions.first?.hidden == true)
        XCTAssertNil(actions.first?.text)
        XCTAssertEqual(actions.first?.line, "Typed a password (hidden)")
        let typed = actions.last?.text ?? ""
        XCTAssertFalse(typed.contains("sk-ant"), typed)
        XCTAssertTrue(typed.contains("•••"), typed)
    }

    func testScrollsMergeAndStepsAreTold() {
        var recorder = AgentActionRecorder()
        recorder.add(AgentInputEvent(.scroll(dx: 0, dy: -1), t: 1))
        recorder.add(AgentInputEvent(.scroll(dx: 0, dy: -1), t: 1.2))
        recorder.add(AgentInputEvent(.scroll(dx: 0, dy: -1), t: 1.4))
        recorder.add(AgentInputEvent(.scroll(dx: 0, dy: 2), t: 1.5))
        recorder.step("Open the pricing page", at: 2)
        recorder.step("   ", at: 3)
        let actions = recorder.finish()
        XCTAssertEqual(actions.map(\.kind), [.scroll, .scroll, .step])
        XCTAssertEqual(actions[0].text, "down")
        XCTAssertEqual(actions[0].end, 1.4)
        XCTAssertEqual(actions[1].text, "up")
        XCTAssertEqual(actions[2].source, .told)
        XCTAssertEqual(actions[2].line, "Open the pricing page")
    }

    // MARK: The log

    func testLogRoundTripsWithChaptersAndSummary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = Take(folder: folder)
        let log = AgentActionLog(agent: "Claude Code", task: "Sign up", startedAt: Date(timeIntervalSince1970: 1_800_000_000), actions: [
            AgentAction(kind: .step, source: .told, t: 0.5, text: "Open the signup page"),
            AgentAction(kind: .click, t: 1, x: 1, y: 2),
            AgentAction(kind: .type, t: 2, end: 3, text: "lee"),
            AgentAction(kind: .key, t: 4, text: "Return"),
            AgentAction(kind: .step, source: .told, t: 5, text: "Check the welcome email"),
        ])
        try log.write(for: take)
        let read = try XCTUnwrap(AgentActionLog.load(for: take))
        XCTAssertEqual(read, log)
        XCTAssertEqual(read.chapters.map(\.title), ["Open the signup page", "Check the welcome email"])
        XCTAssertEqual(read.summary, "3 actions: 1 click, 1 typed, 1 key")
    }

    func testOlderOrHandWrittenActionsStillRead() throws {
        let json = #"{"version":1,"agent":"Codex","startedAt":"2026-10-27T10:00:00Z","actions":[{"kind":"click","t":1.5}]}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try AgentActionLog.read(from: url)
        XCTAssertEqual(log.actions.first?.source, .seen)
        XCTAssertEqual(log.actions.first?.hidden, false)
    }

    // MARK: Skip the waiting

    func testWaitingCutsKeepAMomentEitherSideAndSpareSpeech() {
        let actions = [
            AgentAction(kind: .click, t: 2),
            AgentAction(kind: .type, t: 20, end: 22, text: "hi"),
            AgentAction(kind: .click, t: 25),
        ]
        let speech = [TimeSpan(start: 8, end: 10)]
        let cuts = AgentWaiting.cuts(actions: actions, speech: speech, duration: 30)
        let expected: [(Double, Double)] = [
            (3.5, 7.2),     // after the click, up to the speech
            (11.5, 19.2),   // after the speech, up to the typing
            (26.5, 29.2),   // the tail after the last click
        ]
        XCTAssertEqual(cuts.count, expected.count)
        for (cut, want) in zip(cuts, expected) {
            XCTAssertEqual(cut.start, want.0, accuracy: 0.001)
            XCTAssertEqual(cut.end, want.1, accuracy: 0.001)
        }
        XCTAssertTrue(cuts.allSatisfy { $0.state == .proposed && $0.reason == Cut.Reason.waiting })
        XCTAssertEqual(AgentWaiting.total(cuts), 3.7 + 7.7 + 2.7, accuracy: 0.001)
    }

    func testNoActionsMeansNoCuts() {
        XCTAssertTrue(AgentWaiting.cuts(actions: [], speech: [], duration: 120).isEmpty)
        XCTAssertTrue(AgentWaiting.cuts(actions: [AgentAction(kind: .click, t: 1)], speech: [], duration: 0).isEmpty)
    }

    func testProposingTwiceDoesNotRepeat() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = Take(folder: folder)
        XCTAssertTrue(try AgentWaiting.propose(on: take, transcript: nil, sourceDuration: 60).isEmpty,
                      "not an agent take")
        try AgentActionLog(agent: "Claude", actions: [AgentAction(kind: .click, t: 1), AgentAction(kind: .click, t: 40)])
            .write(for: take)
        let first = try AgentWaiting.propose(on: take, transcript: nil, sourceDuration: 60)
        XCTAssertEqual(first.count, 2)
        let again = try AgentWaiting.propose(on: take, transcript: nil, sourceDuration: 60)
        XCTAssertTrue(again.isEmpty)
        let edits = try EditList.read(from: take.editsURL)
        XCTAssertEqual(edits.cuts.count, 2)
        XCTAssertEqual(edits.sourceDuration, 60)
    }
}
