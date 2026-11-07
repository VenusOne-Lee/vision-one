import XCTest
@testable import VisionOneKit

final class PendingExportsTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pending-exports.json")
    }

    func testRoundTripsAndDropsEmptyEntries() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = URL(fileURLWithPath: "/tmp/take-a", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/take-b", isDirectory: true)
        let pending = PendingExports(entries: [
            .init(takeFolder: a, presets: [.whatsapp], keep: [0..<3.5]),
            .init(takeFolder: b, presets: []),
            .init(takeFolder: a, presets: [.vertical]),
        ])
        try pending.save(to: url)
        let loaded = PendingExports.load(from: url)
        XCTAssertEqual(loaded.entries, [.init(takeFolder: a, presets: [.whatsapp], keep: [0..<3.5])])
    }

    func testSavingNothingRemovesTheFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try PendingExports(entries: [.init(takeFolder: URL(fileURLWithPath: "/tmp/x"), presets: [.whatsapp])]).save(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try PendingExports().save(to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(PendingExports.load(from: url).isEmpty)
    }

    func testUnfinishedLeavesOutDoneAndCancelled() {
        var batch = ExportBatch([.whatsapp, .vertical])
        XCTAssertEqual(batch.unfinished, batch.presets)
        let first = batch.presets[0]
        batch.start(first)
        batch.fail(first, message: "no")
        XCTAssertEqual(batch.unfinished, [batch.presets[1]])
        batch.cancel()
        XCTAssertEqual(batch.unfinished, [])
    }
}
