import XCTest
@testable import VisionOneKit

final class MenuBarMarkTests: XCTestCase {
    func testRecordingWinsThenNeedsYouThenWorking() {
        XCTAssertEqual(MenuBarMark.current(isLive: true, statuses: [.needsYou, .working]), .recording)
        XCTAssertEqual(MenuBarMark.current(isLive: false, statuses: [.working, .needsYou, .done]), .needsYou)
        XCTAssertEqual(MenuBarMark.current(isLive: false, statuses: [.done, .working]), .working)
        XCTAssertEqual(MenuBarMark.current(isLive: false, statuses: [.done, .ready, .failed]), .idle)
        XCTAssertEqual(MenuBarMark.current(isLive: false, statuses: []), .idle)
    }

    func testMarksLookDifferentAndRecordingKeepsItsLook() {
        XCTAssertEqual(Set(MenuBarMark.allCases.map(\.systemImage)).count, MenuBarMark.allCases.count)
        XCTAssertEqual(MenuBarMark.idle.systemImage, "circle.dashed")
        XCTAssertEqual(MenuBarMark.recording.systemImage, "record.circle.fill")
        XCTAssertEqual(MenuBarMark.idle.accessibilityLabel, "Vision One")
    }

    func testOpenStatusesSkipArchivedTasks() {
        let project = UUID()
        var waiting = DeskTask(projectID: project, title: "Queued ask")
        waiting.queued = ["make it shorter"]
        var archived = DeskTask(projectID: project, title: "Old")
        archived.queued = ["never mind"]
        archived.archived = true
        let quiet = DeskTask(projectID: project, title: "Done")
        let snapshot = DeskSnapshot(tasks: [waiting, archived, quiet])
        XCTAssertEqual(snapshot.openStatuses, [.working, .done])
        XCTAssertEqual(MenuBarMark.current(isLive: false, statuses: snapshot.openStatuses), .working)
    }
}
