import XCTest
@testable import VisionOneKit

final class EditListTests: XCTestCase {
    private func cut(_ start: Double, _ end: Double, _ state: Cut.State = .accepted) -> Cut {
        Cut(span: TimeSpan(start: start, end: end), state: state)
    }

    func testNoCutsKeepsEverything() {
        let list = EditList(sourceDuration: 10)
        XCTAssertEqual(list.keptSpans, [TimeSpan(start: 0, end: 10)])
        XCTAssertEqual(list.outputDuration, 10)
        XCTAssertEqual(list.outputTime(forSource: 4), 4)
    }

    func testOverlappingCutsInAnyOrderMerge() {
        var list = EditList(sourceDuration: 10)
        list.add(cut(5, 7))
        list.add(cut(2, 3))
        list.add(cut(6, 8))
        XCTAssertEqual(list.removedSpans, [TimeSpan(start: 2, end: 3), TimeSpan(start: 5, end: 8)])
        XCTAssertEqual(list.keptSpans, [
            TimeSpan(start: 0, end: 2), TimeSpan(start: 3, end: 5), TimeSpan(start: 8, end: 10),
        ])
        XCTAssertEqual(list.outputDuration, 6, accuracy: 1e-9)
    }

    func testOnlyAcceptedCutsChangeTheVideo() {
        var list = EditList(sourceDuration: 10)
        list.add(cut(1, 2, .proposed))
        list.add(cut(3, 4, .rejected))
        XCTAssertEqual(list.outputDuration, 10)
        XCTAssertFalse(list.isRemoved(1.5))
    }

    func testTimeMappingBothWays() {
        var list = EditList(sourceDuration: 10)
        list.add(cut(2, 4))
        XCTAssertEqual(list.outputTime(forSource: 1), 1)
        XCTAssertNil(list.outputTime(forSource: 3))
        XCTAssertEqual(list.outputTime(forSource: 5)!, 3, accuracy: 1e-9)
        XCTAssertEqual(list.outputTime(forSource: 10)!, 8, accuracy: 1e-9)
        XCTAssertEqual(list.sourceTime(forOutput: 1), 1)
        XCTAssertEqual(list.sourceTime(forOutput: 2), 4, accuracy: 1e-9)
        XCTAssertEqual(list.sourceTime(forOutput: 3), 5, accuracy: 1e-9)
        XCTAssertEqual(list.sourceTime(forOutput: 99), 10)
    }

    func testCutsAreClampedAndEmptyOnesIgnored() {
        var list = EditList(sourceDuration: 10)
        XCTAssertNil(list.add(cut(11, 12)))
        let clamped = list.add(cut(-1, 1))
        XCTAssertEqual(clamped?.start, 0)
        XCTAssertEqual(list.cuts.count, 1)
    }

    func testProposeSkipsAnythingAlreadyDecided() {
        var list = EditList(sourceDuration: 10)
        list.add(cut(1, 2, .rejected))
        list.add(cut(5, 6))
        let added = list.propose([cut(1.5, 1.8), cut(5.5, 7), cut(8, 9)])
        XCTAssertEqual(added.map(\.start), [8])
        XCTAssertEqual(added.first?.state, .proposed)
        XCTAssertEqual(list.cuts.count, 3)
    }

    func testAcceptAll() {
        var list = EditList(sourceDuration: 10)
        list.add(cut(1, 2, .proposed))
        list.add(cut(3, 4, .rejected))
        list.acceptAllProposed()
        XCTAssertEqual(list.cuts.map(\.state), [.accepted, .rejected])
    }

    func testRestoreTrimsAndSplits() {
        var list = EditList(sourceDuration: 20)
        let long = list.add(cut(2, 10))!
        list.add(cut(12, 14))
        list.add(cut(15, 16, .proposed))
        list.restore(TimeSpan(start: 4, end: 6))   // splits the long cut
        list.restore(TimeSpan(start: 11, end: 16)) // removes 12-14, leaves the proposal
        XCTAssertEqual(list.removedSpans, [TimeSpan(start: 2, end: 4), TimeSpan(start: 6, end: 10)])
        XCTAssertEqual(list.cuts.first?.id, long.id)
        XCTAssertTrue(list.cuts.contains { $0.state == .proposed })
    }

    func testRoundTripsAndLoadsMissingFileAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let empty = try EditList.load(from: url, sourceDuration: 12)
        XCTAssertEqual(empty, EditList(sourceDuration: 12))

        var list = EditList(sourceDuration: 12)
        list.add(Cut(span: TimeSpan(start: 1, end: 2), reason: Cut.Reason.filler, state: .proposed))
        try list.write(to: url)
        XCTAssertEqual(try EditList.load(from: url, sourceDuration: 12), list)
    }

    func testTakeHasEditsFile() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/Vision One x", isDirectory: true))
        XCTAssertEqual(take.editsURL.lastPathComponent, "edits.json")
    }
}
