import Foundation

/// The four caption styles from the design system. Every style draws
/// ink on a white panel in Bricolage Grotesque; keywords take the
/// builder's ring colour, never tally orange and never green.
public enum CaptionStyle: String, CaseIterable, Codable, Sendable {
    /// Calm: plain two-line subtitles.
    case subtitle
    /// Each word darkens as it is said. The default for shorts.
    case wordByWord
    /// Lively: word by word, with numbers and names in the ring colour.
    case keyword
    /// Viral: one to three heavy words, each popping in as it is said.
    case boldPop

    public var title: String {
        switch self {
        case .subtitle: return "Subtitle"
        case .wordByWord: return "Word by word"
        case .keyword: return "Keyword"
        case .boldPop: return "Bold pop"
        }
    }

    public var layout: CaptionLayout {
        switch self {
        case .subtitle: return .subtitle
        case .wordByWord, .keyword: return .wordByWord
        case .boldPop: return .boldPop
        }
    }

    /// Words not yet said are muted and the spoken word is in ink.
    public var highlightsSpokenWord: Bool { self != .subtitle }

    /// Keywords are drawn in the ring colour.
    public var colorsKeywords: Bool { self == .keyword || self == .boldPop }

    public var weight: Weight {
        switch self {
        case .subtitle: return .medium
        case .wordByWord, .keyword: return .bold
        case .boldPop: return .heavy
        }
    }

    public enum Weight: String, Codable, Sendable {
        case medium, bold, heavy
    }

    /// Font size as a fraction of the frame's shorter side, so a 1080p
    /// landscape video and a 1080x1920 short get the same physical size.
    public var relativeFontSize: Double {
        switch self {
        case .subtitle: return 0.042
        case .wordByWord, .keyword: return 0.068
        case .boldPop: return 0.09
        }
    }

    /// Distance of the caption's bottom edge from the bottom of the frame,
    /// as a fraction of frame height. Shorts sit higher to clear the
    /// platform's own buttons and caption text.
    public func bottomInset(isVertical: Bool) -> Double {
        switch self {
        case .subtitle: return isVertical ? 0.16 : 0.07
        case .wordByWord, .keyword, .boldPop: return isVertical ? 0.26 : 0.12
        }
    }

    /// Scale for the Bold pop animation: words start 12% larger and
    /// settle over 0.15 s. Other styles never scale.
    public func scale(secondsSinceWordStart dt: Double) -> Double {
        guard self == .boldPop, dt >= 0, dt < Self.popDuration else { return 1 }
        let progress = dt / Self.popDuration
        return 1 + 0.12 * (1 - progress) * (1 - progress)
    }

    static let popDuration = 0.15

    /// The style the Energy dial picks (Calm, Lively, Viral).
    public static func forEnergy(_ energy: Int) -> CaptionStyle {
        switch energy {
        case ..<1: return .subtitle
        case 1: return .keyword
        default: return .boldPop
        }
    }
}

/// The caption choices saved with a take or template. Everything here
/// is adjustable in the editor: style, size, where the caption sits
/// (drag it on the preview) and how many words show at once.
public struct CaptionSettings: Codable, Equatable, Sendable {
    public var isOn: Bool
    public var style: CaptionStyle
    /// Draw the captions into the video. Off means file only.
    public var burnIn: Bool
    /// Also write captions.srt and captions.vtt next to the video.
    public var writeFiles: Bool
    /// Product names to colour as keywords.
    public var keywordNames: [String]
    public var mzansiSpelling: Bool
    /// Multiplies the style's font size. Kept within `sizeRange`.
    public var sizeScale: Double
    /// Bottom of the caption as a fraction of frame height, set by
    /// dragging it on the preview. Nil uses the style's default spot.
    public var position: Double?
    /// Words on screen at once in the word styles. Nil uses the style's.
    public var wordsAtATime: Int?
    /// Burn in and write files in this translated language
    /// (transcript.zu.json). Nil uses the words as spoken.
    public var language: SALanguage?

    public static let sizeRange: ClosedRange<Double> = 0.6...1.8
    public static let positionRange: ClosedRange<Double> = 0.02...0.9
    public static let wordsRange: ClosedRange<Int> = 1...8

    public init(
        isOn: Bool = true,
        style: CaptionStyle = .subtitle,
        burnIn: Bool = true,
        writeFiles: Bool = true,
        keywordNames: [String] = [],
        mzansiSpelling: Bool = true,
        sizeScale: Double = 1,
        position: Double? = nil,
        wordsAtATime: Int? = nil,
        language: SALanguage? = nil
    ) {
        self.isOn = isOn
        self.style = style
        self.burnIn = burnIn
        self.writeFiles = writeFiles
        self.keywordNames = keywordNames
        self.mzansiSpelling = mzansiSpelling
        self.sizeScale = sizeScale
        self.position = position
        self.wordsAtATime = wordsAtATime
        self.language = language
    }

    // Fields added later decode with defaults, so older files still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style) ?? .subtitle
        burnIn = try c.decodeIfPresent(Bool.self, forKey: .burnIn) ?? true
        writeFiles = try c.decodeIfPresent(Bool.self, forKey: .writeFiles) ?? true
        keywordNames = try c.decodeIfPresent([String].self, forKey: .keywordNames) ?? []
        mzansiSpelling = try c.decodeIfPresent(Bool.self, forKey: .mzansiSpelling) ?? true
        sizeScale = try c.decodeIfPresent(Double.self, forKey: .sizeScale) ?? 1
        position = try c.decodeIfPresent(Double.self, forKey: .position)
        wordsAtATime = try c.decodeIfPresent(Int.self, forKey: .wordsAtATime)
        language = try? c.decodeIfPresent(SALanguage.self, forKey: .language)
    }

    /// Font size as a fraction of the frame's shorter side.
    public var relativeFontSize: Double {
        style.relativeFontSize * min(max(sizeScale, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }

    /// Bottom of the caption as a fraction of frame height.
    public func bottomInset(isVertical: Bool) -> Double {
        guard let position else { return style.bottomInset(isVertical: isVertical) }
        return min(max(position, Self.positionRange.lowerBound), Self.positionRange.upperBound)
    }

    /// The style's layout with the user's words-at-a-time applied. Bigger
    /// text gets shorter lines so it still fits the frame.
    public var layout: CaptionLayout {
        var layout = style.layout
        if style != .subtitle, let words = wordsAtATime {
            let n = min(max(words, Self.wordsRange.lowerBound), Self.wordsRange.upperBound)
            layout.maxWordsPerCue = n
            layout.maxCharactersPerLine = max(layout.maxCharactersPerLine, n * 6)
        }
        let scale = min(max(sizeScale, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        if scale > 1 {
            layout.maxCharactersPerLine = max(8, Int((Double(layout.maxCharactersPerLine) / scale).rounded()))
        }
        return layout
    }

    public var builder: CaptionBuilder {
        CaptionBuilder(layout: layout, keywordNames: Set(keywordNames), mzansiSpelling: mzansiSpelling)
    }
}
