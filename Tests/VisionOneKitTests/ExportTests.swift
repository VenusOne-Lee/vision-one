import XCTest
@testable import VisionOneKit

final class ExportTimelineTests: XCTestCase {
    func testWholeTakeWhenNothingIsCut() {
        let timeline = ExportTimeline(keep: nil, sourceDuration: 12, frameRate: 30)
        XCTAssertEqual(timeline.segments.count, 1)
        XCTAssertEqual(timeline.duration, 12, accuracy: 1e-9)
        XCTAssertTrue(timeline.joins.isEmpty)
    }

    func testSortsMergesAndClamps() {
        let timeline = ExportTimeline(keep: [8..<20, 0..<2, 1..<3, 5..<6], sourceDuration: 10, frameRate: 0)
        XCTAssertEqual(timeline.segments.map(\.source), [0..<3, 5..<6, 8..<10])
        XCTAssertEqual(timeline.segments.map(\.outputStart), [0, 3, 4])
        XCTAssertEqual(timeline.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(timeline.joins, [3, 4])
    }

    func testSnapsToFramesAndDropsSlivers() {
        // 1.01 snaps to 1.0 at 30 fps; a 5 ms span is less than a frame.
        let timeline = ExportTimeline(keep: [1.01..<2.0, 4.0..<4.005], sourceDuration: 10, frameRate: 30)
        XCTAssertEqual(timeline.segments.count, 1)
        XCTAssertEqual(timeline.segments[0].source.lowerBound, 1.0, accuracy: 1e-9)
    }

    func testMapsTimesBothWays() {
        let timeline = ExportTimeline(keep: [0..<2, 5..<7], sourceDuration: 10, frameRate: 0)
        XCTAssertEqual(timeline.outputTime(forSource: 5.5) ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertNil(timeline.outputTime(forSource: 3))
        XCTAssertEqual(timeline.sourceTime(forOutput: 3.0) ?? -1, 6.0, accuracy: 1e-9)
        XCTAssertNil(timeline.sourceTime(forOutput: 4.5))
    }

    func testUsesOnlyAcceptedCuts() {
        var edits = EditList(sourceDuration: 10)
        _ = edits.add(Cut(span: TimeSpan(start: 2, end: 4), state: .accepted))
        _ = edits.add(Cut(span: TimeSpan(start: 6, end: 7), state: .proposed))
        let timeline = ExportTimeline(edits: edits, frameRate: 30)
        XCTAssertEqual(timeline.segments.map(\.source), [0..<2, 4..<10])
        XCTAssertEqual(timeline.duration, edits.outputDuration, accuracy: 1e-9)
    }

    func testEverythingCutIsEmpty() {
        let timeline = ExportTimeline(keep: [], sourceDuration: 10, frameRate: 30)
        XCTAssertTrue(timeline.segments.isEmpty)
        XCTAssertEqual(timeline.duration, 0)
    }
}

final class ExportPlannerTests: XCTestCase {
    /// A 14-inch MacBook Pro screen at 2x.
    let retina = ExportSource(width: 3024, height: 1964, frameRate: 60)

    func testOriginalKeepsSizeAndFrameRate() throws {
        let s = try ExportPlanner.settings(for: .original, source: retina, duration: 60)
        XCTAssertEqual(s.width, 3024)
        XCTAssertEqual(s.height, 1964)
        XCTAssertEqual(s.frameRate, 60)
        XCTAssertLessThanOrEqual(s.videoBitRate, 40_000_000)
    }

    func testOriginalCaps5KAt3840() throws {
        let s = try ExportPlanner.settings(for: .original, source: ExportSource(width: 5120, height: 2880, frameRate: 30), duration: 10)
        XCTAssertEqual(s.width, 3840)
        XCTAssertEqual(s.height, 2160)
    }

    func test720pIsEvenAndKeepsShape() throws {
        let s = try ExportPlanner.settings(for: .hd720, source: retina, duration: 60)
        XCTAssertEqual(s.height, 720)
        XCTAssertEqual(s.width % 2, 0)
        XCTAssertEqual(Double(s.width) / Double(s.height), 3024.0 / 1964.0, accuracy: 0.01)
        XCTAssertEqual(s.frameRate, 30)
    }

    func testNeverScalesUp() throws {
        let small = ExportSource(width: 1280, height: 720, frameRate: 30)
        let s = try ExportPlanner.settings(for: .hd1080, source: small, duration: 10)
        XCTAssertEqual(s.width, 1280)
        XCTAssertEqual(s.height, 720)
    }

    func testWhatsAppStaysUnder16MB() throws {
        for duration in [5.0, 30, 60, 90, 120, 180, 240, 300, 400] {
            let s = try ExportPlanner.settings(for: .whatsapp, source: retina, duration: duration)
            XCTAssertLessThan(s.estimatedBytes(duration: duration), 16_000_000, "\(duration) s")
            XCTAssertLessThanOrEqual(s.frameRate, 30)
        }
    }

    func testWhatsAppStepsDownForLongVideos() throws {
        let short = try ExportPlanner.settings(for: .whatsapp, source: retina, duration: 30)
        let long = try ExportPlanner.settings(for: .whatsapp, source: retina, duration: 300)
        XCTAssertEqual(short.height, 720)
        XCTAssertLessThan(long.height, short.height)
    }

    func testWhatsAppShortVideoDoesNotWasteData() throws {
        let s = try ExportPlanner.settings(for: .whatsapp, source: retina, duration: 10)
        XCTAssertLessThan(s.estimatedBytes(duration: 10), 5_000_000)
    }

    func testWhatsAppTooLongSaysHowManyParts() {
        let max = ExportPlanner.maxDuration(for: .whatsapp, source: retina) ?? 0
        XCTAssertGreaterThan(max, 300)
        XCTAssertThrowsError(try ExportPlanner.settings(for: .whatsapp, source: retina, duration: max * 2.5)) { error in
            guard case let ExportPlanError.tooLongForSizeLimit(_, parts) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(parts, 3)
        }
    }

    func testEmptyVideoThrows() {
        XCTAssertThrowsError(try ExportPlanner.settings(for: .hd720, source: retina, duration: 0))
    }

    func testOnlyWhatsAppHasALimit() {
        XCTAssertNil(ExportPlanner.maxDuration(for: .original))
        XCTAssertEqual(ExportPreset.allCases.compactMap(\.sizeLimitBytes), [16_000_000])
    }
}

final class ExportNamingTests: XCTestCase {
    func testExportSitsInTakeFolder() {
        let take = Take(folder: URL(fileURLWithPath: "/tmp/Vision One 2026-10-27 at 10.53.12", isDirectory: true))
        XCTAssertEqual(take.exportURL(for: .original).lastPathComponent, "Vision One 2026-10-27 at 10.53.12.mp4")
        XCTAssertEqual(take.exportURL(for: .whatsapp).lastPathComponent, "Vision One 2026-10-27 at 10.53.12 (WhatsApp).mp4")
    }

    func testStatus() {
        XCTAssertEqual(ExportPhase.exporting(preset: .whatsapp, progress: 0.426).status, "Exporting WhatsApp 42%")
        XCTAssertEqual(ExportPhase.size(14_249_000), "14.2 MB")
    }
}
