import XCTest
@testable import VisionOneKit

final class TranscriptEditingTests: XCTestCase {
    // "So, um, today we ship." from docs/TRANSCRIPT.md
    private let words = [
        TimeSpan(start: 0.42, end: 0.61),
        TimeSpan(start: 0.70, end: 0.95),
        TimeSpan(start: 1.30, end: 1.62),
        TimeSpan(start: 1.62, end: 1.74),
        TimeSpan(start: 1.74, end: 2.10),
    ]

    func testDeletingAWordTakesHalfOfEachGap() throws {
        let span = try XCTUnwrap(EditList.span(deleting: 1...1, of: words, sourceDuration: 4.2))
        XCTAssertEqual(span.start, 0.655, accuracy: 1e-9) // halfway between 0.61 and 0.70
        XCTAssertEqual(span.end, 1.125, accuracy: 1e-9)   // halfway between 0.95 and 1.30
    }

    func testTouchingWordsCutAtTheEdge() throws {
        let span = try XCTUnwrap(EditList.span(deleting: 3...3, of: words, sourceDuration: 4.2))
        XCTAssertEqual(span.start, 1.62, accuracy: 1e-9)
        XCTAssertEqual(span.end, 1.74, accuracy: 1e-9)
    }

    func testFirstAndLastWordsRunToTheEdges() throws {
        let opening = try XCTUnwrap(EditList.span(deleting: 0...1, of: words, sourceDuration: 4.2))
        XCTAssertEqual(opening.start, 0)
        let closing = try XCTUnwrap(EditList.span(deleting: 4...4, of: words, sourceDuration: 4.2))
        XCTAssertEqual(closing.end, 4.2)
    }

    func testOutOfRangeIsNil() {
        XCTAssertNil(EditList.span(deleting: 3...5, of: words, sourceDuration: 4.2))
    }

    func testMarks() throws {
        var list = EditList(sourceDuration: 4.2)
        list.add(Cut(span: try XCTUnwrap(EditList.span(deleting: 2...2, of: words, sourceDuration: 4.2))))
        list.add(Cut(span: TimeSpan(start: 0.66, end: 1.0), reason: Cut.Reason.filler, state: .proposed))
        // A cut that only grazes the next word's edge doesn't mark it.
        list.add(Cut(span: TimeSpan(start: 1.62, end: 1.63)))
        XCTAssertEqual(list.marks(for: words), [
            .kept, .proposed(reason: "filler"), .cut, .kept, .kept,
        ])
    }

    func testNearestKeptSourceSkipsCuts() {
        var list = EditList(sourceDuration: 10)
        list.add(Cut(span: TimeSpan(start: 2, end: 4)))
        XCTAssertEqual(list.nearestKeptSource(1), 1)
        XCTAssertEqual(list.nearestKeptSource(3), 4)
    }
}

final class TakeListingTests: XCTestCase {
    func testListsRecordedTakesNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = TakeLibrary(folder: root)
        let older = try library.newTake(at: Date(timeIntervalSince1970: 1_793_000_000))
        let newer = try library.newTake(at: Date(timeIntervalSince1970: 1_793_090_000))
        _ = try library.newTake(at: Date(timeIntervalSince1970: 1_793_095_000)) // no recording yet
        for take in [older, newer] {
            FileManager.default.createFile(atPath: take.screenURL.path, contents: Data())
        }
        XCTAssertEqual(library.takes().map(\.name), [newer.name, older.name])
    }

    func testMissingFolderIsEmpty() {
        let library = TakeLibrary(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertTrue(library.takes().isEmpty)
    }
}
