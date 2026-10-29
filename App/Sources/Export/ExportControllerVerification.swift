import Foundation
import VisionOneKit

/// Controlled controller-level regression: callbacks outlive their encoder,
/// as they can when hopping from the media queue onto the main actor.
@MainActor
enum ExportControllerVerification {
    private final class Request {
        let exporter: VideoExporter
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<VideoExporter.Output, Error>

        init(_ exporter: VideoExporter, _ progress: @escaping @Sendable (Double) -> Void,
             _ continuation: CheckedContinuation<VideoExporter.Output, Error>) {
            self.exporter = exporter
            self.progress = progress
            self.continuation = continuation
        }

        func finish() {
            continuation.resume(returning: VideoExporter.Output(
                url: exporter.take.exportURL(for: exporter.preset), bytes: 123,
                timeline: ExportTimeline(keep: nil, sourceDuration: 1, frameRate: 30), videoStart: 0))
        }
    }

    private final class Driver {
        var requests: [Request] = []
        func run(_ exporter: VideoExporter, progress: @escaping @Sendable (Double) -> Void) async throws -> VideoExporter.Output {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(exporter, progress, continuation))
            }
        }
    }

    private static func wait(_ message: String, until ready: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw MediaVerification.Failure(message: message)
    }

    static func run(in root: URL) async throws {
        let a = Take(folder: root.appendingPathComponent("export-run-A"))
        let b = Take(folder: root.appendingPathComponent("export-run-B"))
        for take in [a, b] {
            try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
            try take.saveCaptionSettings(CaptionSettings(isOn: false))
        }
        let driver = Driver()
        let controller = ExportController { exporter, progress in
            try await driver.run(exporter, progress: progress)
        }
        controller.export(a, preset: .hd720)
        try await wait("Export A did not start") { driver.requests.count == 1 }
        let first = driver.requests[0]
        first.progress(0.4)
        try await wait("Valid A progress was lost") { controller.phase == .exporting(preset: .hd720, progress: 0.4) }
        first.finish()
        try await wait("Export A did not finish") { !controller.phase.isBusy }

        controller.export(b, preset: .vertical)
        try await wait("Export B did not start") { driver.requests.count == 2 }
        let second = driver.requests[1]
        second.progress(0.2)
        try await wait("Valid B progress was lost") { controller.phase == .exporting(preset: .vertical, progress: 0.2) }
        // A's callback is deliberately retained and delivered while B is active.
        first.progress(0.99)
        second.progress(0.1)
        try await Task.sleep(for: .milliseconds(50))
        try MediaVerification.require(controller.phase == .exporting(preset: .vertical, progress: 0.2),
                                      "A's delayed callback changed B's preset or progress")
        controller.cancel()
        // Simulate an encoder that returns success despite being cancelled.
        second.finish()
        try await wait("Cancelled export did not settle") { !controller.phase.isBusy }
        try MediaVerification.require(controller.phase == .idle && controller.warning == nil,
                                      "Cancelled encoder published success or subtitle warnings")

        controller.export(b, preset: .square)
        try await wait("Retry did not start") { driver.requests.count == 3 }
        let retry = driver.requests[2]
        second.progress(0.98)
        retry.progress(0.3)
        try await wait("Retry progress was lost") { controller.phase == .exporting(preset: .square, progress: 0.3) }
        try await Task.sleep(for: .milliseconds(50))
        try MediaVerification.require(controller.phase == .exporting(preset: .square, progress: 0.3),
                                      "Cancelled run changed retry progress")
        retry.continuation.resume(throwing: MediaVerification.Failure(message: "Controlled encoder failure"))
        try await wait("Failed export did not settle") { !controller.phase.isBusy }
        try MediaVerification.require(controller.phase == .failed(message: "Controlled encoder failure"),
                                      "Current run's failure was lost")

        controller.export(b, preset: .square)
        try await wait("Failure retry did not start") { driver.requests.count == 4 }
        let final = driver.requests[3]
        final.progress(0.6)
        try await wait("Final run progress was lost") { controller.phase == .exporting(preset: .square, progress: 0.6) }
        final.finish()
        try await wait("Final run did not finish") { !controller.phase.isBusy }
        first.progress(1)
        retry.progress(1)
        try await Task.sleep(for: .milliseconds(50))
        try MediaVerification.require(controller.phase == .done(preset: .square, url: b.exportURL(for: .square), bytes: 123),
                                      "Delayed callback replaced current terminal state")
        let report: [String: Any] = ["delayedAWhileB": true, "validCurrentProgress": true,
                                    "cancelledSuccessRejected": true, "failureAndRetry": true,
                                    "scope": "Controlled native ExportController callbacks; media output is verified separately"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("export-run-identity.json"))
        print("Export controller run identity verification passed")
    }
}
