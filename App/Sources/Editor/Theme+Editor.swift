import AppKit
import SwiftUI

/// Editor tokens from docs/DESIGN.md, beside the shared ones in Theme.
extension Theme {
    static let selection = Color(hex: 0x1F3FBF)
    static let selectionSoft = Color(hex: 0xE4E8FA)
    static let cutText = Color(hex: 0xA9A8A3)
    static let fillerBackground = Color(hex: 0xFBEFD3)
    static let fillerText = Color(hex: 0x7A4E05)
    static let ringGold = Color(hex: 0xE0A21B)

    /// Source Serif 4 (bundled, see FontRegistry); the system serif (New
    /// York) if it failed to load, so the transcript still reads like writing.
    static func transcriptFont(size: CGFloat) -> NSFont {
        if let font = NSFont(name: BundledFont.serifRegular, size: size) { return font }
        let system = NSFont.systemFont(ofSize: size)
        if let serif = system.fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: serif, size: size) ?? system
        }
        return system
    }
}
