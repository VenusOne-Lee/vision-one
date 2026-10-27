import XCTest
@testable import VisionOneKit

final class TakeTitleTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vision One 2026-10-27 at 14.41.05 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTitleRoundTripsAndClears() throws {
        let take = Take(folder: folder)
        XCTAssertNil(take.customTitle)
        try take.setTitle("  Launch video\nfor Kasi Eats  ")
        XCTAssertEqual(take.customTitle, "Launch video for Kasi Eats")
        XCTAssertEqual(take.displayTitle(), "Launch video for Kasi Eats")
        try take.setTitle("   ")
        XCTAssertNil(take.customTitle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.titleURL.path))
    }

    func testTitleIsCappedAt80Characters() throws {
        let take = Take(folder: folder)
        try take.setTitle(String(repeating: "a", count: 120))
        XCTAssertEqual(take.customTitle?.count, 80)
    }

    func testStampWritesThePickOnce() throws {
        let take = Take(folder: folder)
        let plan = try TakePlan.stamp(take, purposeID: "short")
        XCTAssertEqual(plan?.purposeID, "short")
        XCTAssertEqual(TakePlan.load(for: take)?.energy, Purpose.short.energy)
        // A later pick on Home doesn't rewrite a take that already has one.
        XCTAssertNil(try TakePlan.stamp(take, purposeID: "launch"))
        XCTAssertEqual(TakePlan.load(for: take)?.purposeID, "short")
    }

    func testJustRecordWritesNothing() throws {
        let take = Take(folder: folder)
        XCTAssertNil(try TakePlan.stamp(take, purposeID: nil))
        XCTAssertNil(try TakePlan.stamp(take, purposeID: "nonsense"))
        XCTAssertNil(TakePlan.load(for: take))
    }
}
