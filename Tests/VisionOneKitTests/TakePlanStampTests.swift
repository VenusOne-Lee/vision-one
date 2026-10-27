import XCTest
@testable import VisionOneKit

final class TakePlanStampTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vision One 2026-10-27 at 14.41.05 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
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

    func testStampCarriesHomesEnergy() throws {
        let take = Take(folder: folder)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vision-one-stamp-\(UUID().uuidString)"))
        XCTAssertNil(try TakePlan.stamp(take, from: defaults))
        defaults.set("tutorial", forKey: TakePlan.nextPurposeKey)
        defaults.set("viral", forKey: TakePlan.nextEnergyKey)
        try TakePlan.stamp(take, from: defaults)
        XCTAssertEqual(TakePlan.load(for: take)?.purposeID, "tutorial")
        XCTAssertEqual(TakePlan.load(for: take)?.energy, .viral)
    }
}
