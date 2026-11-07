import XCTest
@testable import VisionOneKit

final class AgentMarksTests: XCTestCase {
    private func log() -> AgentActionLog {
        AgentActionLog(agent: "Claude Code", actions: [
            AgentAction(kind: .click, t: 2, x: 500, y: 250),
            AgentAction(kind: .type, t: 3, text: "hello"),
            AgentAction(kind: .step, source: .told, t: 1, text: "Open the pricing page"),
            AgentAction(kind: .step, source: .told, t: 9, text: "Sign up"),
        ])
    }

    func testClicksArePlacedAsAShareOfTheRecording() throws {
        let marks = try XCTUnwrap(AgentMarks(log: log(), recordedWidth: 1000, recordedHeight: 500))
        XCTAssertEqual(marks.clicks, [AgentMarks.Click(t: 2, x: 0.5, y: 0.5)])
    }

    func testRingShowsBrieflyAfterTheClick() throws {
        let marks = try XCTUnwrap(AgentMarks(log: log(), recordedWidth: 1000, recordedHeight: 500))
        XCTAssertTrue(marks.rings(atSource: 1.9).isEmpty)
        let ring = try XCTUnwrap(marks.rings(atSource: 2.3).first)
        XCTAssertEqual(ring.progress, 0.5, accuracy: 1e-9)
        XCTAssertTrue(marks.rings(atSource: 2.7).isEmpty)
    }

    func testWithoutTheRecordedSizeOnlyNotesAreKept() throws {
        let marks = try XCTUnwrap(AgentMarks(log: log(), recordedWidth: nil, recordedHeight: nil))
        XCTAssertTrue(marks.clicks.isEmpty)
        XCTAssertEqual(marks.notes.count, 2)
    }

    func testNothingToDrawGivesNil() {
        let empty = AgentActionLog(agent: "Claude", actions: [AgentAction(kind: .type, t: 1, text: "x")])
        XCTAssertNil(AgentMarks(log: empty, recordedWidth: 100, recordedHeight: 100))
    }

    func testStepsFollowTheCutsAndStayReadable() throws {
        let marks = try XCTUnwrap(AgentMarks(log: log(), recordedWidth: 1000, recordedHeight: 500))
        // Keep 0–4 s and 8–12 s: the second note lands at 5 s of the export.
        let timeline = ExportTimeline(keep: [0..<4, 8..<12], sourceDuration: 12, frameRate: 0)
        let steps = marks.steps(on: timeline)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].text, "Open the pricing page")
        XCTAssertEqual(steps[0].start, 1, accuracy: 1e-6)
        XCTAssertEqual(steps[0].end, 5, accuracy: 1e-6)
        XCTAssertEqual(steps[1].start, 5, accuracy: 1e-6)
        XCTAssertEqual(steps[1].end, 8, accuracy: 1e-6)
    }
}
