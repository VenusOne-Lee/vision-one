import AppKit
import SwiftUI
import VisionOneKit

/// Tokens from docs/DESIGN.md, read from the look picked in Settings →
/// Appearance (VisionOneKit's `ThemePalette`, contrast tested for every
/// preset). Paper, ink on white, is the default. Tally orange means
/// "recording is live" in every look and nothing else. There is no
/// success green. Hosting roots add `.themed()` so a new look repaints.
/// Components that use these are in DesignSystem/.
enum Theme {
    /// The look in use. Set by ThemeStore on the main thread.
    static var palette: ThemePalette { ThemeState.palette }
    static var appearance: Appearance { ThemeState.appearance }

    static var paper: Color { Color(hex: palette.paper) }
    static var canvas: Color { Color(hex: palette.canvas) }
    /// Panel edges and dividers.
    static var line: Color { Color(hex: palette.line) }
    /// Edges of fields, switches and anything you can click.
    static var lineStrong: Color { Color(hex: palette.lineStrong) }
    static var text: Color { Color(hex: palette.text) }
    /// Secondary text.
    static var textMuted: Color { Color(hex: palette.textMuted) }
    /// Placeholders and tertiary text.
    static var textFaint: Color { Color(hex: palette.textFaint) }
    /// The primary button: ink, or the ring colour with Bold buttons.
    static var button: Color { Color(hex: palette.button) }
    static var onButton: Color { Color(hex: palette.onButton) }
    /// The builder's ring colour: rings, the camera bubble edge.
    static var accent: Color { Color(hex: palette.accent) }
    /// Behind the video.
    static var stage: Color { Color(hex: palette.stage) }
    /// Only for "recording is live". Never buttons, links or badges.
    static let tally = Color(hex: ThemePalette.tally)
    static var tallySoft: Color { Color(hex: palette.tallySoft) }
    static var error: Color { Color(hex: palette.error) }
    static var errorSoft: Color { Color(hex: palette.errorSoft) }

    /// Roomy density opens the larger gaps up by a quarter; the small
    /// ones stay put so rows still line up.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static var md: CGFloat { roomy(16) }
        static var lg: CGFloat { roomy(24) }
        static var xl: CGFloat { roomy(32) }
        static var xxl: CGFloat { roomy(48) }

        private static func roomy(_ value: CGFloat) -> CGFloat {
            Theme.appearance.density == .roomy ? (value * 1.25).rounded() : value
        }
    }

    /// The menu bar panel: wide enough that no label wraps.
    enum Panel {
        static let width: CGFloat = 320
        static let inset: CGFloat = 14
    }

    /// Corners: Sharp, Soft (the default) or Round.
    enum Radius {
        static var sm: CGFloat { scaled(4) }
        static var md: CGFloat { scaled(8) }
        static var lg: CGFloat { scaled(12) }
        static let full: CGFloat = 9999
        /// The composer and other big inputs.
        static var composer: CGFloat { scaled(14) }

        private static func scaled(_ value: CGFloat) -> CGFloat {
            switch Theme.appearance.corners {
            case .sharp: value / 2
            case .soft: value
            case .round: (value * 1.5).rounded()
            }
        }
    }

    /// Control heights. Hit targets never go below `hitMin`.
    enum Size {
        static let controlSmall: CGFloat = 22
        static let control: CGFloat = 28
        static let controlLarge: CGFloat = 36
        static let hitMin: CGFloat = 24
        static let toolbar: CGFloat = 44
        static var row: CGFloat { Theme.appearance.density == .roomy ? 52 : 44 }
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
    static var floatShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        (Color.black.opacity(palette.isDark ? 0.45 : 0.12), 9, 6)
    }
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
}
