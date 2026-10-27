import AppKit
import VisionOneKit

/// Runs one export at a time and publishes its progress for the UI.
@MainActor
final class ExportController: ObservableObject {
    static let shared = ExportController()

    @Published private(set) var phase: ExportPhase = .idle
    private var task: Task<Void, Never>?

    /// Exports `take`. `keep` overrides the kept spans in source seconds;
    /// nil exports what the editor kept in edits.json. `overlays` draw on every frame
    /// (the corner logo); the camera bubble comes from the take itself. `captionRingHex` burns
    /// in the take's captions with keywords in that colour. `cards` adds
    /// the brand intro and outro. Subtitle files are written next to the
    /// video only once it's done, timed to match it.
    func export(_ take: Take, preset: ExportPreset, keep: [Range<Double>]? = nil, overlays: [ExportOverlay] = [],
                captionRingHex: UInt32? = nil, cards: CardMaker? = nil) {
        guard !phase.isBusy else { return }
        phase = .exporting(preset: preset, progress: 0)
        var exporter = VideoExporter(take: take, keep: keep, preset: preset, overlays: overlays,
                                     captionRingHex: captionRingHex, cards: cards)
        exporter.ring = BrandStore.shared.kit.ring

        task = Task {
            do {
                let output = try await exporter.run { progress in
                    Task { @MainActor in
                        // Updates can land out of order; the ring only
                        // moves forward.
                        guard case let .exporting(_, current) = self.phase else { return }
                        self.phase = .exporting(preset: preset, progress: max(current, progress))
                    }
                }
                CaptionExport.writeFiles(for: take, video: output.url, timeline: output.timeline,
                                         offset: output.videoStart)
                phase = .done(preset: preset, url: output.url, bytes: output.bytes)
            } catch is CancellationError {
                phase = .idle
            } catch {
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
