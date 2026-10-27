import Foundation

/// Colour values from docs/DESIGN.md as plain sRGB hex, so `swift test`
/// can check contrast without SwiftUI. The app's `Theme` reads these.
/// Light only; tally orange means "recording is live" and nothing else.
public enum DesignTokens {
    public static let paper: UInt32 = 0xFFFFFF
    public static let canvas: UInt32 = 0xF4F4F1
    /// Panel edges and dividers. Decorative only (1.3:1 on paper).
    public static let line: UInt32 = 0xE2E1DC
    /// Control edges: fields, switches when off, checkboxes. 3:1 or more
    /// on paper and canvas, as WCAG 1.4.11 asks of a control's boundary.
    public static let lineStrong: UInt32 = 0x8A8984
    public static let text: UInt32 = 0x121212
    public static let textMuted: UInt32 = 0x5C5B57
    /// Placeholders and tertiary text, still 4.5:1 on paper.
    public static let textFaint: UInt32 = 0x767570
    public static let tally: UInt32 = 0xFF5A1F
    public static let tallySoft: UInt32 = 0xFFE3D6
    public static let fillerBackground: UInt32 = 0xFBEFD3
    public static let fillerText: UInt32 = 0x7A4E05
    /// Cut words: struck through and inactive, so below 4.5:1 on purpose.
    public static let cutText: UInt32 = 0xA9A8A3
    public static let selection: UInt32 = 0x1F3FBF
    public static let selectionSoft: UInt32 = 0xE4E8FA
    public static let error: UInt32 = 0xB3261E
    public static let errorSoft: UInt32 = 0xF9E1DE

    public static let ringRed: UInt32 = 0xD62B2B
    public static let ringBlue: UInt32 = 0x1F3FBF
    public static let ringGold: UInt32 = 0xE0A21B
    public static let ringBlack: UInt32 = 0x121212
    public static let accentPurple: UInt32 = 0x7A3FBF
    public static let accentPink: UInt32 = 0xC2306E

    /// Text and the grounds it sits on, each needing 4.5:1 (WCAG 2.2 AA).
    public static let textPairs: [(name: String, foreground: UInt32, background: UInt32)] = [
        ("text on paper", text, paper),
        ("text on canvas", text, canvas),
        ("muted on paper", textMuted, paper),
        ("muted on canvas", textMuted, canvas),
        ("faint on paper", textFaint, paper),
        ("paper on ink button", paper, text),
        ("selection on paper", selection, paper),
        ("text on selection tint", text, selectionSoft),
        ("error on paper", error, paper),
        ("error on error tint", error, errorSoft),
        ("filler text on filler tint", fillerText, fillerBackground),
    ]

    /// Control edges and focus rings, each needing 3:1 (WCAG 1.4.11).
    public static let markPairs: [(name: String, foreground: UInt32, background: UInt32)] = [
        ("control edge on paper", lineStrong, paper),
        ("control edge on canvas", lineStrong, canvas),
        ("focus ring on paper", selection, paper),
        ("focus ring on canvas", selection, canvas),
        ("ink button on paper", text, paper),
        ("tally dot on paper", tally, paper),
    ]

    /// WCAG relative luminance of an sRGB colour.
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// WCAG contrast ratio, 1 to 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
