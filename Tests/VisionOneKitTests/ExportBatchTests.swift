import XCTest
@testable import VisionOneKit

final class AspectRatioTests: XCTestCase {
    func testNamesCommonShapes() {
        XCTAssertEqual(AspectRatio.label(width: 1920, height: 1080), "16:9")
        XCTAssertEqual(AspectRatio.label(width: 2560, height: 1600), "16:10")
        XCTAssertEqual(AspectRatio.label(width: 1080, height: 1920), "9:16")
        XCTAssertEqual(AspectRatio.label(width: 1080, height: 1080), "1:1")
        // 1366 x 768 is within 2% of 16:9.
        XCTAssertEqual(AspectRatio.label(width: 1366, height: 768), "16:9")
    }

    func testOddShapesReadAsDecimal() {
        // A MacBook Pro screen is between 3:2 and 16:10.
        XCTAssertEqual(AspectRatio.label(width: 3024, height: 1964), "1.54:1")
        XCTAssertEqual(AspectRatio.label(width: 0, height: 1080), "")
    }
}

final class ExportEstimateTests: XCTestCase {
    let source = ExportSource(width: 1920, height: 1080, frameRate: 30)

    func testPlainPresetShowsShapeLengthAndSize() {
        let estimate = ExportEstimate(preset: .hd1080, source: source, duration: 60)
        XCTAssertEqual(estimate.ratio, "16:9")
        XCTAssertEqual(estimate.width, 1920)
        XCTAssertNil(estimate.problem)
        // (6_220_800 video + 160_000 sound) bits/s for a minute, plus 2%.
        XCTAssertEqual(Double(estimate.bytes ?? 0), 48_813_120, accuracy: 2)
        XCTAssertEqual(estimate.detail, "16:9 · 1:00 · ~49 MB")
    }

    func testSizeLimitedNeverEstimatesOverTheLimit() throws {
        let estimate = ExportEstimate(preset: .whatsapp, source: source, duration: 120)
        let bytes = try XCTUnwrap(estimate.bytes)
        XCTAssertLessThanOrEqual(bytes, 16_000_000)
        XCTAssertTrue(estimate.detail.hasPrefix("16:9 · 2:00 · ~"))
    }

    func testTooLongSaysSo() {
        let estimate = ExportEstimate(preset: .whatsapp, source: source, duration: 3600)
        XCTAssertNil(estimate.bytes)
        XCTAssertEqual(estimate.shortProblem, "too long")
        XCTAssertNotNil(estimate.problem)
        XCTAssertEqual(estimate.detail, "16:9 · 1:00:00 · too long")
    }

    func testEverythingCut() {
        let estimate = ExportEstimate(preset: .hd720, source: source, duration: 0)
        XCTAssertEqual(estimate.shortProblem, "all cut")
    }

    func testSizeText() {
        XCTAssertEqual(ExportEstimate.size(4_200_000), "~4.2 MB")
        XCTAssertEqual(ExportEstimate.size(38_400_000), "~38 MB")
    }
}

final class ExportBatchTests: XCTestCase {
    let url720 = URL(fileURLWithPath: "/tmp/take (720p).mp4")
    let url1080 = URL(fileURLWithPath: "/tmp/take (1080p).mp4")

    func testRunsInPresetOrderOnce() {
        let batch = ExportBatch([.whatsapp, .hd1080, .hd1080])
        XCTAssertEqual(batch.presets, [.hd1080, .whatsapp])
        XCTAssertEqual(batch.next, .hd1080)
        XCTAssertNil(batch.current)
        XCTAssertTrue(batch.isRunning)
    }

    func testFollowsTheExporterOneAfterAnother() {
        var batch = ExportBatch([.hd1080, .hd720])
        batch.start(.hd1080)
        XCTAssertEqual(batch.current, .hd1080)
        XCTAssertNil(batch.next, "nothing else starts while one runs")

        batch.apply(.exporting(preset: .hd1080, progress: 0.5))
        XCTAssertEqual(batch.status(of: .hd1080)?.progress, 0.5)
        // Late updates don't move the ring backwards.
        batch.apply(.exporting(preset: .hd1080, progress: 0.3))
        XCTAssertEqual(batch.status(of: .hd1080)?.progress, 0.5)
        XCTAssertEqual(batch.progress, 0.25, accuracy: 1e-9)

        batch.apply(.done(preset: .hd1080, url: url1080, bytes: 10))
        XCTAssertEqual(batch.status(of: .hd1080), .done(url: url1080, bytes: 10))
        XCTAssertEqual(batch.next, .hd720)

        batch.start(.hd720)
        batch.apply(.exporting(preset: .hd720, progress: 0))
        batch.apply(.done(preset: .hd720, url: url720, bytes: 5))
        XCTAssertTrue(batch.isFinished)
        XCTAssertEqual(batch.exported, [url1080, url720])
        XCTAssertEqual(batch.progress, 1, accuracy: 1e-9)
    }

    func testIgnoresPhasesLeftFromAnEarlierExport() {
        var batch = ExportBatch([.hd1080])
        batch.start(.hd1080)
        // A finished 1080p export from before, and an idle exporter, seen
        // before this export reports it's running.
        batch.apply(.done(preset: .hd1080, url: url1080, bytes: 1))
        batch.apply(.idle)
        batch.apply(.failed(message: "old"))
        XCTAssertEqual(batch.status(of: .hd1080), .starting)
        // Another preset's progress isn't ours.
        batch.apply(.exporting(preset: .hd720, progress: 0.9))
        XCTAssertEqual(batch.status(of: .hd1080), .starting)
    }

    func testAFailureMovesOnToTheNext() {
        var batch = ExportBatch([.hd1080, .whatsapp])
        batch.start(.hd1080)
        batch.apply(.exporting(preset: .hd1080, progress: 0.1))
        batch.apply(.failed(message: "Couldn't write the video."))
        XCTAssertEqual(batch.failures, ["Couldn't write the video."])
        XCTAssertEqual(batch.next, .whatsapp)

        batch.start(.whatsapp)
        batch.fail(.whatsapp, message: "Another export is running.")
        XCTAssertTrue(batch.isFinished)
        XCTAssertTrue(batch.exported.isEmpty)
    }

    func testCancelStopsTheRest() {
        var batch = ExportBatch([.original, .hd1080, .hd720])
        batch.start(.original)
        batch.apply(.exporting(preset: .original, progress: 0.4))
        batch.cancel()
        XCTAssertNil(batch.next)
        XCTAssertEqual(batch.status(of: .hd1080), .cancelled)
        XCTAssertTrue(batch.isRunning, "the running export ends when the exporter says so")

        batch.apply(.idle)
        XCTAssertEqual(batch.status(of: .original), .cancelled)
        XCTAssertTrue(batch.isFinished)
    }

    func testCancelBeforeTheExporterStartedStillEnds() {
        var batch = ExportBatch([.hd720])
        batch.start(.hd720)
        batch.cancel()
        batch.apply(.idle)
        XCTAssertEqual(batch.status(of: .hd720), .cancelled)
    }
}

extension ExportBatchTests {
    func testRetryKeepsSuccessfulFilesAndOnlyQueuesUnfinishedOutputs() {
        var batch = ExportBatch([.hd1080, .vertical])
        let url = URL(fileURLWithPath: "/tmp/finished.mp4")
        batch.start(.hd1080)
        batch.apply(.exporting(preset: .hd1080, progress: 1))
        batch.apply(.done(preset: .hd1080, url: url, bytes: 123))
        batch.start(.vertical)
        batch.apply(.exporting(preset: .vertical, progress: 0.3))
        batch.apply(.failed(message: "Temporary failure"))
        batch.retryUnfinished()
        XCTAssertEqual(batch.exported, [url])
        XCTAssertEqual(batch.next, .vertical)
        XCTAssertEqual(batch.status(of: .hd1080), .done(url: url, bytes: 123))
    }
}
