import Foundation

/// The export sheet's "2 of 3 · about 40 s left". Plain arithmetic, so
/// it's tested without AVFoundation.
public enum ExportProgress {
    /// 0...1 over the whole batch, each preset counted by `weight` (its
    /// pixels per second is a fair guess at how long it takes to encode).
    /// Finished presets count as whole.
    public static func overall(_ batch: ExportBatch, weight: (ExportPreset) -> Double) -> Double {
        var total = 0.0
        var done = 0.0
        for preset in batch.presets {
            guard let status = batch.status(of: preset) else { continue }
            let w = max(0, weight(preset))
            total += w
            done += w * (status.isFinished ? 1 : (status.progress ?? 0))
        }
        return total > 0 ? min(max(done / total, 0), 1) : batch.progress
    }

    /// Seconds left, from how far along it is after `elapsed` seconds. Nil
    /// until there's enough to go on, so the first guess isn't wild.
    public static func remaining(progress: Double, elapsed: Double) -> Double? {
        guard progress >= 0.05, progress < 1, elapsed >= 2 else { return nil }
        return elapsed / progress * (1 - progress)
    }

    /// "about 40 s left", "about 3 min left", "a few seconds left".
    public static func remainingText(_ seconds: Double) -> String {
        if seconds < 10 { return "a few seconds left" }
        if seconds < 60 { return "about \(Int((seconds / 5).rounded()) * 5) s left" }
        let minutes = Int((seconds / 60).rounded())
        return minutes <= 1 ? "about a minute left" : "about \(minutes) min left"
    }
}

extension ExportBatch {
    /// Finished files by preset.
    public var files: [ExportPreset: URL] {
        var files: [ExportPreset: URL] = [:]
        for preset in presets {
            if case let .done(url, _)? = status(of: preset) { files[preset] = url }
        }
        return files
    }
}
