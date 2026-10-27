import Foundation

/// How words are grouped into cues. The subtitle numbers follow the
/// Netflix English timed text guide (42 characters, 2 lines, 20 characters
/// a second, 5/6 s to 7 s on screen); the social numbers follow what
/// short-form apps do (one short line of a few words).
public struct CaptionLayout: Equatable, Sendable {
    public var maxCharactersPerLine: Int
    public var maxLines: Int
    /// Cap on words per cue, for word-by-word styles. Nil means no cap.
    public var maxWordsPerCue: Int?
    /// Shortest time a cue stays up, so it can be read.
    public var minDuration: Double
    /// Longest time a cue may span.
    public var maxDuration: Double
    /// Reading speed used to stretch short cues.
    public var maxCharactersPerSecond: Double
    /// A silence at least this long starts a new cue, so captions never
    /// hang over a pause.
    public var pauseBreak: Double
    /// Space kept between one cue's end and the next one's start.
    public var gap: Double

    public init(
        maxCharactersPerLine: Int,
        maxLines: Int,
        maxWordsPerCue: Int? = nil,
        minDuration: Double = 5.0 / 6.0,
        maxDuration: Double = 7,
        maxCharactersPerSecond: Double = 20,
        pauseBreak: Double = 0.6,
        gap: Double = 2.0 / 30.0
    ) {
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxLines = max(1, maxLines)
        self.maxWordsPerCue = maxWordsPerCue
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.maxCharactersPerSecond = maxCharactersPerSecond
        self.pauseBreak = pauseBreak
        self.gap = gap
    }

    /// Two lines of up to 42 characters: YouTube, tutorials, SRT files.
    public static let subtitle = CaptionLayout(maxCharactersPerLine: 42, maxLines: 2)

    /// One line of up to four words: TikTok, Reels, Shorts.
    public static let wordByWord = CaptionLayout(
        maxCharactersPerLine: 22, maxLines: 1, maxWordsPerCue: 4,
        minDuration: 0.3, maxDuration: 3, maxCharactersPerSecond: 30, pauseBreak: 0.4
    )

    /// One to three big words at a time.
    public static let boldPop = CaptionLayout(
        maxCharactersPerLine: 16, maxLines: 1, maxWordsPerCue: 3,
        minDuration: 0.25, maxDuration: 2, maxCharactersPerSecond: 30, pauseBreak: 0.35
    )
}
