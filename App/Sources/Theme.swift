import AppKit
import SwiftUI
import VisionOneKit

/// Tokens from docs/DESIGN.md. Light only. Tally orange means "recording
/// is live" and nothing else. There is no success green. The values live
/// in VisionOneKit's DesignTokens so `swift test` checks their contrast.
/// Components that use these are in DesignSystem/.
enum Theme {
    static let paper = Color(hex: DesignTokens.paper)
    static let canvas = Color(hex: DesignTokens.canvas)
    /// Panel edges and dividers. With Increase Contrast on, as strong as a control edge.
    static let line = Color(hex: DesignTokens.line, increased: DesignTokens.lineStrong)
    /// Edges of fields, switches and anything you can click.
    static let lineStrong = Color(hex: DesignTokens.lineStrong, increased: DesignTokens.text)
    static let text = Color(hex: DesignTokens.text)
    /// Secondary text. Becomes ink with Increase Contrast on.
    static let textMuted = Color(hex: DesignTokens.textMuted, increased: DesignTokens.text)
    /// Placeholders and tertiary text.
    static let textFaint = Color(hex: DesignTokens.textFaint, increased: DesignTokens.textMuted)
    /// Only for "recording is live". Never buttons, links or badges.
    static let tally = Color(hex: DesignTokens.tally)
    static let tallySoft = Color(hex: DesignTokens.tallySoft)
    static let error = Color(hex: DesignTokens.error)
    static let errorSoft = Color(hex: DesignTokens.errorSoft)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    /// The menu bar panel: wide enough that no label wraps.
    enum Panel {
        static let width: CGFloat = 320
        static let inset: CGFloat = 14
    }

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let full: CGFloat = 9999
    }

    /// Control heights. Hit targets never go below `hitMin`.
    enum Size {
        static let controlSmall: CGFloat = 22
        static let control: CGFloat = 28
        static let controlLarge: CGFloat = 36
        static let hitMin: CGFloat = 24
        static let toolbar: CGFloat = 44
        static let row: CGFloat = 44
    }

    /// Dashed means proposed or not done yet; solid means accepted or done.
    enum Stroke {
        static let hairline: CGFloat = 1
        static let ring: CGFloat = 1.5
        static let focus: CGFloat = 2
        static let dash: [CGFloat] = [4, 3]
        static let dashSmall: [CGFloat] = [2.5, 2]
    }

    /// Minimal and functional. Only the ring and the tally light animate
    /// for long; everything else is a short state change.
    enum Motion {
        static let micro: Double = 0.08
        static let short: Double = 0.2
        static let medium: Double = 0.32
        static let long: Double = 0.6
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        static var enter: Animation { .easeOut(duration: short) }
        static var exit: Animation { .easeIn(duration: short) }
        static var move: Animation { .easeInOut(duration: medium) }
    }

    /// One soft offset shadow for floating things (recorder bar, sheets).
    static let floatShadow = (color: Color.black.opacity(0.12), radius: CGFloat(9), y: CGFloat(6))
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A colour that swaps to `increased` while Increase Contrast is on
    /// (System Settings → Accessibility → Display).
    init(hex: UInt32, increased: UInt32) {
        self.init(nsColor: NSColor(name: nil) { _ in
            let value = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? increased : hex
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}
