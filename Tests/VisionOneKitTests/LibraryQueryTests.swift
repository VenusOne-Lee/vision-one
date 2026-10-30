import XCTest
@testable import VisionOneKit

final class LibraryQueryTests: XCTestCase {
    private func item(_ name: String, title: String, at seconds: TimeInterval?, duration: Double? = nil,
                      exported: Bool = false, cuts: Int = 0, words: String? = nil,
                      purpose: String? = nil) -> TakeListing {
        TakeListing(take: Take(folder: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)),
                    title: title,
                    recordedAt: seconds.map { Date(timeIntervalSince1970: $0) },
                    duration: duration, isExported: exported, suggestedCuts: cuts, transcriptText: words,
                    purposeTitle: purpose)
    }

    private var items: [TakeListing] {
        [
            item("c", title: "Today at 14:41", at: 300, duration: 40, cuts: 3, words: "Here is the login demo"),
            item("b", title: "Café pitch", at: 200, duration: 125, exported: true, words: "Our pitch for investors"),
            item("a", title: "Yesterday at 09:05", at: 100, duration: 12, purpose: "Tutorial"),
            item("x", title: "Holiday clips", at: nil, duration: nil),
        ]
    }

    private func names(_ query: LibraryQuery) -> [String] {
        query.apply(to: items).map(\.take.name)
    }

    func testNewestFirstByDefaultWithUndatedLast() {
        XCTAssertEqual(names(LibraryQuery()), ["c", "b", "a", "x"])
    }

    func testOtherSorts() {
        XCTAssertEqual(names(LibraryQuery(sort: .oldest)), ["a", "b", "c", "x"])
        XCTAssertEqual(names(LibraryQuery(sort: .longest)), ["b", "c", "a", "x"])
        XCTAssertEqual(names(LibraryQuery(sort: .title)), ["b", "x", "c", "a"])
    }

    func testSearchMatchesEveryWordInTitleOrTranscript() {
        XCTAssertEqual(names(LibraryQuery(search: "demo LOGIN")), ["c"])
        XCTAssertEqual(names(LibraryQuery(search: "cafe")), ["b"])
        XCTAssertEqual(names(LibraryQuery(search: "pitch investors")), ["b"])
        XCTAssertEqual(names(LibraryQuery(search: "pitch login")), [])
        XCTAssertEqual(names(LibraryQuery(search: "tutorial")), ["a"])
        XCTAssertTrue(LibraryQuery(search: "  ").apply(to: items).count == 4)
        XCTAssertFalse(LibraryQuery(search: "  ").isSearching)
    }

    func testFilters() {
        XCTAssertEqual(names(LibraryQuery(filter: .toReview)), ["c"])
        XCTAssertEqual(names(LibraryQuery(filter: .exported)), ["b"])
        XCTAssertEqual(names(LibraryQuery(filter: .notExported)), ["c", "a", "x"])
    }

    func testTitlesAreSavedBesideTheTake() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vision One 2026-10-27 at 14.41.05", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = Take(folder: folder)

        XCTAssertNil(take.customTitle())
        try take.setTitle("  Launch demo\nfor Version One  ")
        XCTAssertEqual(take.customTitle(), "Launch demo for Version One")
        XCTAssertEqual(take.displayTitle(), "Launch demo for Version One")

        try take.setTitle("   ")
        XCTAssertNil(take.customTitle())
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.titleURL.path))
    }
}

extension LibraryQueryTests {
    func testShowEveryTakeClearsSearchAndFilterKeepingSort() {
        var query = LibraryQuery(search: "missing", filter: .exported, sort: .title)
        query.showEveryTake()
        XCTAssertEqual(query.search, "")
        XCTAssertEqual(query.filter, .all)
        XCTAssertEqual(query.sort, .title)
        XCTAssertEqual(query.apply(to: items).count, items.count)
    }

    func testFilteredEmptyCopyDoesNotQuoteAnEmptySearch() {
        XCTAssertEqual(LibraryQuery(filter: .exported).emptyMessage, "No exported videos yet.")
        XCTAssertEqual(LibraryQuery(filter: .toReview).emptyMessage, "No videos need review.")
        XCTAssertTrue(LibraryQuery(search: "launch", filter: .exported).emptyMessage.contains("exported"))
    }

    func testRenameFailureRetainsDraftForRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let take = Take(folder: folder)
        try FileManager.default.createDirectory(at: take.titleURL, withIntermediateDirectories: true)
        var draft = LibraryRenameDraft()
        draft.begin(title: "Old title")
        draft.text = "New title"
        XCTAssertThrowsError(try draft.finish { try take.setTitle($0) })
        XCTAssertTrue(draft.needsRetry)
        XCTAssertFalse(draft.isEditing)
        draft.begin(title: "Old title")
        XCTAssertEqual(draft.text, "New title")
        try FileManager.default.removeItem(at: take.titleURL)
        try draft.finish { try take.setTitle($0) }
        XCTAssertEqual(take.customTitle(), "New title")
        XCTAssertFalse(draft.needsRetry)
    }
}
