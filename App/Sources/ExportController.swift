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
    /// (burned-in captions, later the camera bubble).
    func export(_ take: Take, preset: ExportPreset, keep: [Range<Double>]? = nil, overlays: [ExportOverlay] = []) {
        guard !phase.isBusy else { return }
        phase = .exporting(preset: preset, progress: 0)
        let exporter = VideoExporter(take: take, keep: keep, preset: preset, overlays: overlays)

        task = Task {
            do {
                let (url, bytes) = try await exporter.run { progress in
                    Task { @MainActor in
                        guard case .exporting = self.phase else { return }
                        self.phase = .exporting(preset: preset, progress: progress)
                    }
                }
                phase = .done(preset: preset, url: url, bytes: bytes)
            } catch is CancellationError {
                phase = .idle
            } catch {
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
