import SwiftUI

/// Tokens from docs/DESIGN.md. Light only. Tally orange means "recording
/// is live" and nothing else. There is no success green.
enum Theme {
    static let paper = Color(hex: 0xFFFFFF)
    static let canvas = Color(hex: 0xF4F4F1)
    static let line = Color(hex: 0xE2E1DC)
    static let text = Color(hex: 0x121212)
    static let textMuted = Color(hex: 0x5C5B57)
    static let tally = Color(hex: 0xFF5A1F)
    static let error = Color(hex: 0xB3261E)
    static let errorSoft = Color(hex: 0xF9E1DE)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
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

/// Black pill (primary) or white pill with an ink border (secondary).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(kind == .primary ? Theme.paper : Theme.text)
            .background(
                Capsule().fill(kind == .primary ? Theme.text : Theme.paper)
            )
            .overlay(
                Capsule().strokeBorder(Theme.text, lineWidth: kind == .primary ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
