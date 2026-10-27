import Foundation

/// Every colour one look needs, as sRGB hex. The app's `Theme` reads the
/// current palette, so a look changes every screen at once. Some things
/// never change between looks: tally orange means recording is live, the
/// error colour means an error, and dashed versus solid means proposed
/// versus kept.
public struct ThemePalette: Equatable, Sendable {
    public var paper: UInt32
    public var canvas: UInt32
    /// Panel edges and dividers. Decorative.
    public var line: UInt32
    /// Control edges: 3:1 or more on paper and canvas.
    public var lineStrong: UInt32
    public var text: UInt32
    public var textMuted: UInt32
    public var textFaint: UInt32
    /// The primary button's fill: ink, or the ring colour with Bold buttons.
    public var button: UInt32
    /// Text and icons on `button`.
    public var onButton: UInt32
    /// The builder's ring colour, for identity marks (rings, the bubble edge).
    public var accent: UInt32
    public var selection: UInt32
    public var selectionSoft: UInt32
    public var error: UInt32
    public var errorSoft: UInt32
    public var fillerBackground: UInt32
    public var fillerText: UInt32
    /// Cut words: struck through, below 4.5:1 on purpose.
    public var cutText: UInt32
    public var tallySoft: UInt32
    /// Behind the video, where the take sits like a finished frame.
    public var stage: UInt32
    public var isDark: Bool
    public var isHighContrast: Bool

    /// Recording is live. The same in every look.
    public static let tally: UInt32 = DesignTokens.tally

    /// Ink on paper: docs/DESIGN.md as written.
    public static let paperLight = ThemePalette(
        paper: DesignTokens.paper, canvas: DesignTokens.canvas, line: DesignTokens.line,
        lineStrong: DesignTokens.lineStrong, text: DesignTokens.text, textMuted: DesignTokens.textMuted,
        textFaint: DesignTokens.textFaint, button: DesignTokens.text, onButton: DesignTokens.paper,
        accent: DesignTokens.ringBlue, selection: DesignTokens.selection, selectionSoft: DesignTokens.selectionSoft,
        error: DesignTokens.error, errorSoft: DesignTokens.errorSoft, fillerBackground: DesignTokens.fillerBackground,
        fillerText: DesignTokens.fillerText, cutText: DesignTokens.cutText, tallySoft: DesignTokens.tallySoft,
        stage: 0xECEBE6, isDark: false, isHighContrast: false)

    /// The palette for a set of choices. `increaseContrast` is the macOS
    /// setting (Accessibility → Display), which adds to whatever look is on.
    public static func resolve(_ appearance: Appearance, increaseContrast: Bool = false) -> ThemePalette {
        let high = appearance.contrast == .high || increaseContrast
        var p: ThemePalette
        if appearance.mode == .dark {
            p = high ? .studioHigh : .studio
        } else if high {
            p = .highContrast
        } else {
            p = .paperLight
            switch appearance.tone {
            case .white: break
            case .warm:
                p.paper = 0xFFFDF8; p.canvas = 0xF5F0E6; p.line = 0xE6DFD2; p.lineStrong = 0x8A8274
                p.textMuted = 0x5C564C; p.textFaint = 0x736C60; p.stage = 0xEFE7D8
            case .cool:
                p.paper = 0xFBFBFD; p.canvas = 0xEEF0F4; p.line = 0xDDE1E8; p.lineStrong = 0x838A96
                p.textMuted = 0x555B66; p.textFaint = 0x6C727D; p.stage = 0xE8ECF3
            }
        }
        p.accent = appearance.accent
        if appearance.buttons == .accent, let fill = Self.buttonFill(for: appearance.accent, on: p) {
            p.button = fill
        } else {
            p.button = p.text
        }
        p.onButton = Self.readable(on: p.button)
        return p
    }

    private static let studio = ThemePalette(
        paper: 0x1E1E1C, canvas: 0x151514, line: 0x34332F, lineStrong: 0x7A7872, text: 0xF2F1EC,
        textMuted: 0xA3A29C, textFaint: 0x8F8D87, button: 0xF2F1EC, onButton: 0x121212,
        accent: DesignTokens.ringBlue, selection: 0x9DB0FF, selectionSoft: 0x283252, error: 0xFF8A80,
        errorSoft: 0x3D211E, fillerBackground: 0x3D3218, fillerText: 0xF2C46D, cutText: 0x6A6863,
        tallySoft: 0x4A2516, stage: 0x0E0E0D, isDark: true, isHighContrast: false)

    private static var studioHigh: ThemePalette {
        var p = studio
        p.line = 0x5A5954; p.lineStrong = 0xB5B3AC; p.text = 0xFFFFFF; p.textMuted = 0xD6D5CF
        p.textFaint = 0xBDBCB6; p.errorSoft = 0x2A1513; p.button = 0xFFFFFF; p.isHighContrast = true
        return p
    }

    private static var highContrast: ThemePalette {
        var p = paperLight
        p.canvas = 0xFFFFFF; p.line = 0xB9B8B2; p.lineStrong = 0x3A3A38; p.text = 0x000000
        p.textMuted = 0x3A3A38; p.textFaint = 0x4A4A47; p.selection = 0x1533A6; p.error = 0x8E1A13
        p.cutText = 0x777672; p.fillerText = 0x5A3700; p.button = 0x000000; p.stage = 0xE6E6E3
        p.isHighContrast = true
        return p
    }

    // MARK: Buttons in the ring colour

    /// Why a ring colour can't fill buttons, or nil when it can. Orange
    /// means recording and red means an error, so rings near either keep
    /// ink buttons. So do greys and black, which are ink already.
    public static func buttonRefusal(for accent: UInt32) -> String? {
        let c = HexColour(accent)
        if c.chroma < 0.15 { return "Black and grey rings already match ink buttons." }
        if c.hueDistance(to: HexColour(DesignTokens.error)) < 20 {
            return "Red means an error, so buttons stay ink."
        }
        if c.hueDistance(to: HexColour(DesignTokens.tally)) < 30 {
            return "Too close to the recording orange, so buttons stay ink."
        }
        if (70...170).contains(c.hue) { return "Vision One has no green buttons." }
        return nil
    }

    /// The ring colour as a button fill on this palette: lightened in a
    /// dark look, darkened in a light one, until it stands out (3:1) and
    /// its label reads (4.5:1). Nil when the ring can't be a button.
    static func buttonFill(for accent: UInt32, on p: ThemePalette) -> UInt32? {
        guard buttonRefusal(for: accent) == nil else { return nil }
        let toward: UInt32 = p.isDark ? 0xFFFFFF : 0x000000
        for step in 0...8 {
            let fill = HexColour.mix(accent, toward, Double(step) / 10)
            let label = readable(on: fill)
            if DesignTokens.contrast(fill, p.paper) >= 3, DesignTokens.contrast(fill, p.canvas) >= 3,
               DesignTokens.contrast(label, fill) >= (p.isHighContrast ? 7 : 4.5) {
                return fill
            }
        }
        return nil
    }

    /// White or ink, whichever reads better on `fill`.
    public static func readable(on fill: UInt32) -> UInt32 {
        DesignTokens.contrast(0xFFFFFF, fill) >= DesignTokens.contrast(0x121212, fill) ? 0xFFFFFF : 0x121212
    }

    // MARK: Checks

    /// Text and its grounds: 4.5:1, or 7:1 in a high-contrast look.
    public var textPairs: [(name: String, foreground: UInt32, background: UInt32)] {
        [
            ("text on paper", text, paper), ("text on canvas", text, canvas),
            ("muted on paper", textMuted, paper), ("muted on canvas", textMuted, canvas),
            ("faint on paper", textFaint, paper), ("label on button", onButton, button),
            ("selection on paper", selection, paper), ("text on selection tint", text, selectionSoft),
            ("error on paper", error, paper), ("error on error tint", error, errorSoft),
            ("filler text on filler tint", fillerText, fillerBackground), ("text on tally tint", text, tallySoft),
        ]
    }

    /// Edges, rings and fills that must be seen: 3:1.
    public var markPairs: [(name: String, foreground: UInt32, background: UInt32)] {
        [
            ("control edge on paper", lineStrong, paper), ("control edge on canvas", lineStrong, canvas),
            ("focus ring on paper", selection, paper), ("focus ring on canvas", selection, canvas),
            ("button on paper", button, paper), ("button on canvas", button, canvas),
            ("tally dot on paper", Self.tally, paper),
        ]
    }

    /// Every pair below its bar, empty when the look passes.
    public var failures: [String] {
        let bar = isHighContrast ? 7.0 : 4.5
        return textPairs.filter { DesignTokens.contrast($0.foreground, $0.background) < bar }.map(\.name)
            + markPairs.filter { DesignTokens.contrast($0.foreground, $0.background) < 3 }.map(\.name)
    }
}

/// An sRGB colour broken into hue and chroma, for the accent rules.
struct HexColour {
    let r: Double, g: Double, b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    var chroma: Double { max(r, g, b) - min(r, g, b) }

    /// 0 to 360.
    var hue: Double {
        let mx = max(r, g, b), c = chroma
        guard c > 0 else { return 0 }
        var h: Double
        if mx == r { h = ((g - b) / c).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / c + 2 }
        else { h = (r - g) / c + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    func hueDistance(to other: HexColour) -> Double {
        let d = abs(hue - other.hue)
        return min(d, 360 - d)
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return ch(16) | ch(8) | ch(0)
    }
}

// MARK: Appearance

/// What the person picked in Settings → Appearance, saved as theme.json.
/// A preset sets the colour choices; corners, density, fonts, panel side
/// and the ring colour are theirs to keep across presets.
public struct Appearance: Codable, Equatable, Sendable {
    public enum Tone: String, Codable, CaseIterable, Sendable { case white, warm, cool }
    public enum Buttons: String, Codable, CaseIterable, Sendable { case ink, accent }
    public enum Contrast: String, Codable, CaseIterable, Sendable { case standard, high }
    public enum Mode: String, Codable, CaseIterable, Sendable { case light, dark }
    public enum Corners: String, Codable, CaseIterable, Sendable { case sharp, soft, round }
    public enum Density: String, Codable, CaseIterable, Sendable { case roomy, compact }
    public enum TranscriptFont: String, Codable, CaseIterable, Sendable { case serif, sans, easyRead }
    public enum PanelSide: String, Codable, CaseIterable, Sendable { case left, right }

    public var tone: Tone = .white
    public var buttons: Buttons = .ink
    public var contrast: Contrast = .standard
    public var mode: Mode = .light
    /// The builder's ring colour.
    public var accent: UInt32 = DesignTokens.ringBlue
    public var corners: Corners = .soft
    public var density: Density = .compact
    public var transcriptFont: TranscriptFont = .serif
    public var panelSide: PanelSide = .right

    public init() {}

    /// Paper, with the ring colour blue.
    public static let standard = Appearance()

    /// The preset these colour choices match, or nil for a custom look.
    public var preset: ThemePreset? {
        ThemePreset.allCases.first { $0.matches(self) }
    }

    public mutating func apply(_ preset: ThemePreset) {
        tone = preset.tone
        buttons = preset.buttons
        contrast = preset.contrast
        mode = preset.mode
    }

    public func applying(_ preset: ThemePreset) -> Appearance {
        var copy = self
        copy.apply(preset)
        return copy
    }

    // Missing keys fall back to defaults, so older and hand-edited theme
    // files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance.standard
        tone = (try? c.decode(Tone.self, forKey: .tone)) ?? d.tone
        buttons = (try? c.decode(Buttons.self, forKey: .buttons)) ?? d.buttons
        contrast = (try? c.decode(Contrast.self, forKey: .contrast)) ?? d.contrast
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? d.mode
        corners = (try? c.decode(Corners.self, forKey: .corners)) ?? d.corners
        density = (try? c.decode(Density.self, forKey: .density)) ?? d.density
        transcriptFont = (try? c.decode(TranscriptFont.self, forKey: .transcriptFont)) ?? d.transcriptFont
        panelSide = (try? c.decode(PanelSide.self, forKey: .panelSide)) ?? d.panelSide
        if let hex = try? c.decode(String.self, forKey: .accent), let value = Appearance.parseHex(hex) {
            accent = value
        } else {
            accent = d.accent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tone, forKey: .tone)
        try c.encode(buttons, forKey: .buttons)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(mode, forKey: .mode)
        try c.encode(Appearance.hexString(accent), forKey: .accent)
        try c.encode(corners, forKey: .corners)
        try c.encode(density, forKey: .density)
        try c.encode(transcriptFont, forKey: .transcriptFont)
        try c.encode(panelSide, forKey: .panelSide)
    }

    private enum CodingKeys: String, CodingKey {
        case tone, buttons, contrast, mode, accent, corners, density, transcriptFont, panelSide
    }

    /// "#1F3FBF".
    public static func hexString(_ value: UInt32) -> String {
        String(format: "#%06X", value & 0xFFFFFF)
    }

    /// "#1F3FBF" or "1f3fbf"; nil if it isn't six hex digits.
    public static func parseHex(_ text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return value
    }
}

/// The six looks from the signed-off harness spec.
public enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case paper, warm, cool, bold, highContrast, studio

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .paper: "Paper"
        case .warm: "Warm"
        case .cool: "Cool"
        case .bold: "Bold"
        case .highContrast: "High contrast"
        case .studio: "Studio"
        }
    }

    public var blurb: String {
        switch self {
        case .paper: "The default. Ink on white."
        case .warm: "Cream paper, softer lines."
        case .cool: "Blue-grey paper for long days."
        case .bold: "Buttons in your ring colour."
        case .highContrast: "Darker lines and text, easier to read."
        case .studio: "Dark, for late nights."
        }
    }

    var tone: Appearance.Tone {
        switch self {
        case .warm: .warm
        case .cool: .cool
        default: .white
        }
    }

    var buttons: Appearance.Buttons { self == .bold ? .accent : .ink }
    var contrast: Appearance.Contrast { self == .highContrast ? .high : .standard }
    var mode: Appearance.Mode { self == .studio ? .dark : .light }

    func matches(_ a: Appearance) -> Bool {
        a.tone == tone && a.buttons == buttons && a.contrast == contrast && a.mode == mode
    }
}

// MARK: theme.json

/// Reads and writes ~/Library/Application Support/Vision One/theme.json.
/// The same file can be shared: Share theme writes one, and opening one
/// loads it.
public enum AppearanceFile {
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Vision One/theme.json")
    }

    /// The saved look, or Paper when there's no file or it can't be read.
    public static func load(from url: URL = defaultURL) -> Appearance {
        guard let data = try? Data(contentsOf: url) else { return .standard }
        return (try? decode(data)) ?? .standard
    }

    public static func save(_ appearance: Appearance, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(appearance).write(to: url, options: .atomic)
    }

    public static func encode(_ appearance: Appearance) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(appearance)
    }

    public static func decode(_ data: Data) throws -> Appearance {
        try JSONDecoder().decode(Appearance.self, from: data)
    }
}
