import AppKit
import CoreText
import SwiftUI

/// PostScript names of the fonts in App/Resources/Fonts. Static OFL
/// instances: Bricolage Grotesque at optical size 12 for controls and at
/// 96 for display, Source Serif 4 for the transcript, JetBrains Mono for
/// every number.
enum BundledFont {
    static let sansRegular = "BricolageGrotesque-Regular"
    static let sansMedium = "BricolageGrotesque-Medium"
    static let sansSemiBold = "BricolageGrotesque-SemiBold"
    static let sansBold = "BricolageGrotesque-Bold"
    static let sansExtraBold = "BricolageGrotesque-ExtraBold"
    static let displayLight = "BricolageGrotesqueDisplay-Light"
    static let displayBold = "BricolageGrotesqueDisplay-Bold"
    static let displayExtraBold = "BricolageGrotesqueDisplay-ExtraBold"
    static let serifRegular = "SourceSerif4-Regular"
    static let serifSemiBold = "SourceSerif4-SemiBold"
    static let serifItalic = "SourceSerif4-Italic"
    static let monoRegular = "JetBrainsMono-Regular"
    static let monoMedium = "JetBrainsMono-Medium"

    /// Registers every bundled font for this process. Call once at launch,
    /// before any window draws. Missing files fall back to the system font.
    static func registerAll(in bundle: Bundle = .main) {
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}

/// The app's type scale. One job per family: Bricolage for the interface,
/// Source Serif 4 for the transcript, JetBrains Mono for numbers. Native
/// menus, alerts and Settings stay in the system font.
enum TypeStyle: CaseIterable {
    /// Empty states, export done, onboarding.
    case display, displayLight
    /// Window and sheet titles.
    case title
    /// Section heads, row titles.
    case headline
    case body, bodyStrong
    /// Small caps-style labels above groups.
    case label
    case caption
    /// Timecodes, sizes, durations: tabular so numbers never jump.
    case mono, monoSmall
    case transcript

    var postScriptName: String {
        switch self {
        case .display: BundledFont.displayExtraBold
        case .displayLight: BundledFont.displayLight
        case .title, .headline, .label: BundledFont.sansSemiBold
        case .body, .caption: BundledFont.sansRegular
        case .bodyStrong: BundledFont.sansMedium
        case .mono, .monoSmall: BundledFont.monoRegular
        case .transcript: BundledFont.serifRegular
        }
    }

    /// Size at the Medium text size.
    var size: CGFloat {
        switch self {
        case .display, .displayLight: 32
        case .title: 17
        case .headline, .body, .bodyStrong: 13
        case .label, .caption, .monoSmall: 11
        case .mono: 12
        case .transcript: 17
        }
    }

    var systemWeight: Font.Weight {
        switch self {
        case .display: .heavy
        case .displayLight: .light
        case .title, .headline, .label: .semibold
        case .bodyStrong: .medium
        default: .regular
        }
    }

    /// Extra space between lines, in points at Medium size.
    var lineSpacing: CGFloat {
        switch self {
        case .transcript: 13 // about 1.8
        case .body, .bodyStrong, .caption: 3
        default: 0
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display, .displayLight: -0.8 // -0.025em
        case .label: 0.66 // 0.06em
        default: 0
        }
    }

    var isUppercase: Bool { self == .label }

    /// The style's font at a given text size. Falls back to the system
    /// font, at the same weight, when the bundled font isn't available.
    func font(scale: CGFloat = 1) -> Font {
        let points = (size * scale).rounded()
        guard NSFont(name: postScriptName, size: points) != nil else {
            let base = Font.system(size: points, weight: systemWeight,
                                   design: self == .transcript ? .serif : .default)
            return self == .mono || self == .monoSmall ? base.monospacedDigit() : base
        }
        return Font.custom(postScriptName, fixedSize: points)
    }

    func nsFont(scale: CGFloat = 1) -> NSFont {
        let points = (size * scale).rounded()
        return NSFont(name: postScriptName, size: points) ?? .systemFont(ofSize: points)
    }
}

/// The Text size setting (View → Bigger Text / Smaller Text): a scale on
/// every TypeStyle, standing in for Dynamic Type, which macOS doesn't
/// offer to apps. Stored in UserDefaults so every window follows it.
enum TextSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge

    static let storageKey = "appearance.textSize"

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: 0.92
        case .medium: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }

    static var current: TextSize {
        TextSize(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .medium
    }

    static func step(_ by: Int) {
        let all = allCases
        let index = all.firstIndex(of: current) ?? 1
        let next = all[min(max(index + by, 0), all.count - 1)]
        UserDefaults.standard.set(next.rawValue, forKey: storageKey)
    }
}

private struct TextStyleModifier: ViewModifier {
    let style: TypeStyle
    @AppStorage(TextSize.storageKey) private var textSize: TextSize = .medium

    func body(content: Content) -> some View {
        let scale = textSize.scale
        content
            .font(style.font(scale: scale))
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing * scale)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Sets a TypeStyle, following the Text size setting.
    /// `Text("Export").textStyle(.headline)`
    func textStyle(_ style: TypeStyle) -> some View {
        modifier(TextStyleModifier(style: style))
    }
}

extension Font {
    /// A TypeStyle's font at the current Text size, for places that need
    /// a plain Font. Prefer `.textStyle(_:)`, which also follows changes.
    static func ds(_ style: TypeStyle) -> Font {
        style.font(scale: TextSize.current.scale)
    }
}
