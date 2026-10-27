import Foundation

/// How a share page looks to viewers. Six preset looks, each made only
/// from colours in docs/DESIGN.md, plus the few things a creator can
/// change on top: accent, background, transcript font, corners and where
/// the transcript sits. Light only, and tally orange is never offered:
/// it means "recording is live" and a share page is never live.
public struct SharePageLook: Codable, Equatable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable, Identifiable {
        case paper
        case warmDesk
        case coolBlue
        case ringRed
        case purple
        case print

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .paper: return "Paper"
            case .warmDesk: return "Warm desk"
            case .coolBlue: return "Cool blue"
            case .ringRed: return "Ring red"
            case .purple: return "Purple"
            case .print: return "Print"
            }
        }

        public var subtitle: String {
            switch self {
            case .paper: return "Vision One as is: ink on paper"
            case .warmDesk: return "Cream paper, serif, calm"
            case .coolBlue: return "Crisp, blue buttons"
            case .ringRed: return "Your red ring leads"
            case .purple: return "Soft and round"
            case .print: return "Sharp, mono transcript"
            }
        }
    }

    public enum TranscriptFont: String, Codable, CaseIterable, Sendable {
        case serif, sans, mono
    }

    public enum Corners: String, Codable, CaseIterable, Sendable {
        case sharp, soft, round

        public var radius: Int {
            switch self {
            case .sharp: return 4
            case .soft: return 12
            case .round: return 22
            }
        }
    }

    /// Where the transcript sits next to the video.
    public enum TranscriptPlace: String, Codable, CaseIterable, Sendable {
        case beside, below, hidden
    }

    /// The preset this look started from. Changing a colour keeps it, so
    /// "Reset" can go back to the preset.
    public var preset: Preset
    /// Page ground.
    public var background: UInt32
    /// Player and transcript panels.
    public var card: UInt32
    public var line: UInt32
    /// Buttons, the play head and the progress bar.
    public var accent: UInt32
    /// The current line and search matches.
    public var soft: UInt32
    /// The creator's ring around their face. Identity, never state.
    public var ring: UInt32
    public var font: TranscriptFont
    public var corners: Corners
    public var transcript: TranscriptPlace

    public init(_ preset: Preset = .paper) {
        self.preset = preset
        transcript = .beside
        switch preset {
        case .paper:
            background = DesignTokens.canvas; card = DesignTokens.paper; line = DesignTokens.line
            accent = DesignTokens.text; soft = DesignTokens.selectionSoft; ring = DesignTokens.ringBlue
            font = .serif; corners = .soft
        case .warmDesk:
            background = Self.canvasWarm; card = Self.paperWarm; line = 0xE6DFD1
            accent = DesignTokens.text; soft = DesignTokens.fillerBackground; ring = DesignTokens.ringGold
            font = .serif; corners = .soft
        case .coolBlue:
            background = Self.canvasCool; card = Self.paperCool; line = 0xDCE0E8
            accent = DesignTokens.ringBlue; soft = DesignTokens.selectionSoft; ring = DesignTokens.ringBlue
            font = .sans; corners = .soft
        case .ringRed:
            background = DesignTokens.canvas; card = DesignTokens.paper; line = DesignTokens.line
            accent = DesignTokens.ringRed; soft = DesignTokens.errorSoft; ring = DesignTokens.ringRed
            font = .sans; corners = .round
        case .purple:
            background = DesignTokens.canvas; card = DesignTokens.paper; line = DesignTokens.line
            accent = DesignTokens.accentPurple; soft = 0xEFE6FA; ring = DesignTokens.accentPurple
            font = .sans; corners = .round
        case .print:
            background = DesignTokens.paper; card = DesignTokens.paper; line = DesignTokens.text
            accent = DesignTokens.text; soft = DesignTokens.canvas; ring = DesignTokens.text
            font = .mono; corners = .sharp
        }
    }

    // From docs/DESIGN.md (paper-warm, canvas-warm, paper-cool, canvas-cool).
    public static let paperWarm: UInt32 = 0xFFFDF8
    public static let canvasWarm: UInt32 = 0xF5F0E6
    public static let paperCool: UInt32 = 0xFBFBFD
    public static let canvasCool: UInt32 = 0xEEF0F4

    /// Accents a creator can pick. Gold is left out: white text on it is
    /// unreadable and it can't carry a button on paper.
    public static let accentChoices: [UInt32] = [
        DesignTokens.text, DesignTokens.ringBlue, DesignTokens.ringRed,
        DesignTokens.accentPurple, DesignTokens.accentPink,
    ]

    public static let backgroundChoices: [UInt32] = [
        DesignTokens.canvas, DesignTokens.paper, canvasWarm, canvasCool,
    ]

    /// Whether `color` can be the accent: never tally orange (or close to
    /// it), and it must stand out from the panels (3:1, WCAG for controls).
    public func allowsAccent(_ color: UInt32) -> Bool {
        !Self.looksLikeTally(color) && DesignTokens.contrast(color, card) >= 3
    }

    /// Sets the accent when it's allowed. Returns false and keeps the old
    /// one otherwise.
    @discardableResult
    public mutating func setAccent(_ color: UInt32) -> Bool {
        guard allowsAccent(color) else { return false }
        accent = color
        return true
    }

    /// Text on accent buttons: white when it reads (4.5:1), ink otherwise.
    public var onAccent: UInt32 {
        DesignTokens.contrast(DesignTokens.paper, accent) >= 4.5 ? DesignTokens.paper : DesignTokens.text
    }

    /// Orange-red hues near the tally light, which only ever means live.
    static func looksLikeTally(_ color: UInt32) -> Bool {
        let r = Double((color >> 16) & 0xFF) / 255, g = Double((color >> 8) & 0xFF) / 255, b = Double(color & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let chroma = maxC - minC
        guard chroma > 0.35, maxC == r else { return false }
        var hue = 60 * ((g - b) / chroma)
        if hue < 0 { hue += 360 }
        // Ring red sits near 0°, gold near 40°; tally is about 16°.
        return hue >= 8 && hue <= 30
    }

    /// The CSS custom properties the share page reads.
    public var cssVariables: [String: String] {
        let fontStack: String
        switch font {
        case .serif: fontStack = "var(--f-serif)"
        case .sans: fontStack = "var(--f-sans)"
        case .mono: fontStack = "var(--f-mono)"
        }
        return [
            "--s-bg": Self.css(background),
            "--s-card": Self.css(card),
            "--s-line": Self.css(line),
            "--s-ink": Self.css(DesignTokens.text),
            "--s-muted": Self.css(DesignTokens.textMuted),
            "--s-accent": Self.css(accent),
            "--s-on": Self.css(onAccent),
            "--s-soft": Self.css(soft),
            "--s-ring": Self.css(ring),
            "--s-body": fontStack,
            "--s-r": "\(corners.radius)px",
        ]
    }

    /// "#1F3FBF".
    public static func css(_ color: UInt32) -> String {
        String(format: "#%06X", color & 0xFFFFFF)
    }
}
