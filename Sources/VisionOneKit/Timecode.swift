import Foundation

/// Formats durations the way the design system asks: HH:MM:SS, always
/// two digits per field, shown in JetBrains Mono with tabular digits so
/// the numbers never jump while recording.
public enum Timecode {
    public static func string(from seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// "2:13" or "1:02:13", for a take's length on its thumbnail.
    public static func short(from seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
