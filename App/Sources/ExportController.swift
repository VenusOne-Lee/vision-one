import AppKit
import VisionOneKit

/// Runs one export at a time and publishes its progress for the UI.
@MainActor
final class ExportController: ObservableObject {
    static let shared = ExportController()

    @Published private(set) var phase: ExportPhase = .idle
    @Published private(set) var warning: String?
    private var task: Task<Void, Never>?
    private var activeRun: UUID?
    typealias Render = @MainActor (VideoExporter, @escaping @Sendable (Double) -> Void) async throws -> VideoExporter.Output
    private let render: Render

    init(render: @escaping Render = { exporter, progress in try await exporter.run(progress: progress) }) {
        self.render = render
    }

    /// Exports `take`. `keep` overrides the kept spans in source seconds;
    /// nil exports what the editor kept in edits.json. `overlays` draw on every frame
    /// (the corner logo); the camera bubble comes from the take itself. `captionRingHex` burns
    /// in the take's captions with keywords in that colour. `cards` adds
    /// the brand intro and outro. Subtitle files are written next to the
    /// video only once it's done, timed to match it.
    func export(_ take: Take, preset: ExportPreset, keep: [Range<Double>]? = nil, overlays: [ExportOverlay] = [],
                captionRingHex: UInt32? = nil, cards: CardMaker? = nil) {
        guard !phase.isBusy else { return }
        let run = UUID()
        activeRun = run
        warning = nil
        phase = .exporting(preset: preset, progress: 0)
        var exporter = VideoExporter(take: take, keep: keep, preset: preset, overlays: overlays,
                                     captionRingHex: captionRingHex, cards: cards)
        exporter.ring = BrandStore.shared.kit.ring

        task = Task {
            defer {
                if activeRun == run {
                    activeRun = nil
                    task = nil
                }
            }
            do {
                let output = try await render(exporter) { progress in
                    Task { @MainActor [weak self] in
                        // Updates can land out of order; the ring only
                        // moves forward.
                        guard let self, self.activeRun == run,
                              case let .exporting(_, current) = self.phase else { return }
                        self.phase = .exporting(preset: preset, progress: max(current, progress))
                    }
                }
                guard activeRun == run else { return }
                try Task.checkCancellation()
                warning = CaptionExport.writeFiles(for: take, video: output.url, timeline: output.timeline,
                                         offset: output.videoStart)
                phase = .done(preset: preset, url: output.url, bytes: output.bytes)
            } catch is CancellationError {
                guard activeRun == run else { return }
                phase = .idle
            } catch {
                guard activeRun == run else { return }
                // A video that didn't make it shouldn't leave captions
                // from an earlier export next to nothing.
                let video = take.exportURL(for: preset)
                if !FileManager.default.fileExists(atPath: video.path) {
                    CaptionExport.removeFiles(beside: video)
                }
                phase = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func revealExport() {
        if case let .done(_, url, _) = phase {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
