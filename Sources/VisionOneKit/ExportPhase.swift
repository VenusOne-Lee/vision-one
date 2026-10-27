import Foundation

/// Where an export is. The ring fills with `progress` while exporting
/// and closes solid when done; there is no success green.
public enum ExportPhase: Equatable, Sendable {
    case idle
    case exporting(preset: ExportPreset, progress: Double)
    case done(preset: ExportPreset, url: URL, bytes: Int64)
    case failed(message: String)

    public var isBusy: Bool {
        if case .exporting = self { return true }
        return false
    }

    /// Plain words for the menu.
    public var status: String {
        switch self {
        case .idle:
            return ""
        case let .exporting(preset, progress):
            return "Exporting \(preset.title) \(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%"
        case let .done(_, url, bytes):
            return "\(url.lastPathComponent) · \(ExportPhase.size(bytes))"
        case let .failed(message):
            return message
        }
    }

    /// "14.2 MB", decimal megabytes like Finder and WhatsApp.
    public static func size(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// What to tell someone when a plan can't be made.
    public static func message(for error: ExportPlanError) -> String {
        switch error {
        case let .tooLongForSizeLimit(maxDuration, parts):
            let minutes = Int(maxDuration / 60)
            return "Too long for WhatsApp. Keep it under \(minutes) min, or send it in \(parts) parts."
        case .emptyVideo:
            return "Nothing to export. Every part of this take is cut."
        }
    }
}
