import XCTest
@testable import VisionOneKit

final class PostDraftTests: XCTestCase {
    func testManualCopyIsOwnedByTakeAndNetworkIncludingExplicitEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Take(folder: root.appendingPathComponent("A"))
        let b = Take(folder: root.appendingPathComponent("B"))
        for take in [a, b] { try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true) }
        try PostDrafts.save("A LinkedIn", destination: "linkedin", for: a)
        let originalA = try Data(contentsOf: PostDrafts.url(for: a))
        try PostDrafts.save("B LinkedIn", destination: "linkedin", for: b)
        try PostDrafts.save("B X", destination: "x", for: b)
        try PostDrafts.save("", destination: "linkedin", for: b)
        XCTAssertEqual(try Data(contentsOf: PostDrafts.url(for: a)), originalA)
        // Recreate Take values, as after navigation/relaunch.
        XCTAssertEqual(try PostDrafts.read(for: Take(folder: a.folder)), ["linkedin": "A LinkedIn"])
        XCTAssertEqual(try PostDrafts.read(for: Take(folder: b.folder)), ["linkedin": "", "x": "B X"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.shareURL.path))
    }

    func testUnreadableDraftDoesNotGetReplacedWhenSavingAnotherNetwork() throws {
        let take = Take(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: take.folder) }
        let bytes = Data("unreadable saved draft".utf8)
        try bytes.write(to: PostDrafts.url(for: take))
        XCTAssertThrowsError(try PostDrafts.save("new", destination: "x", for: take))
        XCTAssertEqual(try Data(contentsOf: PostDrafts.url(for: take)), bytes)
    }

    func testEveryAutomaticPostEntryUsesKeptWordEligibility() throws {
        let take = Take(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: take.folder) }
        XCTAssertFalse(PostCopy.canDraft(for: take))
        let words = (0..<40).map { TranscriptWord(id: $0, text: "word", start: Double($0), end: Double($0 + 1)) }
        try Transcript(language: "en", engine: "test", duration: 40, segments: [.init(words: words)]).write(to: take.transcriptURL)
        XCTAssertTrue(PostCopy.canDraft(for: take))
        // Keeping no words must disable generation even though a transcript exists.
        try EditList(sourceDuration: 40, cuts: [Cut(span: TimeSpan(start: 0, end: 40))]).write(to: take.editsURL)
        XCTAssertFalse(PostCopy.canDraft(for: take))
    }
}
