import AppKit
import SwiftUI
import VisionOneKit

/// Editor tokens from docs/DESIGN.md, beside the shared ones in Theme.
extension Theme {
    static var selection: Color { Color(hex: palette.selection) }
    static var selectionSoft: Color { Color(hex: palette.selectionSoft) }
    static var cutText: Color { Color(hex: palette.cutText) }
    static var fillerBackground: Color { Color(hex: palette.fillerBackground) }
    static var fillerText: Color { Color(hex: palette.fillerText) }
    static let ringGold = Color(hex: DesignTokens.ringGold)

    /// Source Serif 4 (bundled, see FontRegistry); the system serif (New
    /// York) if it failed to load, so the transcript still reads like writing.
    /// Follows Settings → Appearance → Transcript font.
    static func transcriptFont(size: CGFloat) -> NSFont {
        switch appearance.transcriptFont {
        case .serif: break
        case .sans: if let font = NSFont(name: BundledFont.sansRegular, size: size) { return font }
        case .easyRead: return NSFont.systemFont(ofSize: size + 1)
        }
        if let font = NSFont(name: BundledFont.serifRegular, size: size) { return font }
        let system = NSFont.systemFont(ofSize: size)
        if let serif = system.fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: serif, size: size) ?? system
        }
        return system
    }
}
