import Foundation

/// How fast this person talks, in words a minute. Learned from their own
/// takes so the script coach's length estimate fits them, not an average
/// speaker. Pauses between sentences don't count: they're added back by
/// the estimate.
public struct SpeakingPace: Codable, Equatable, Sendable {
    /// A calm demo pace, used until there's a take to learn from.
    public static let standard = 150.0
    /// PowerPoint's Speaker Coach treats 100 to 165 as easy to follow.
    public static let comfortable: ClosedRange<Double> = 130...165

    public var wordsPerMinute: Double
    /// How many takes it was learned from; 0 means `standard`.
    public var takes: Int

    public init(wordsPerMinute: Double = SpeakingPace.standard, takes: Int = 0) {
        self.wordsPerMinute = wordsPerMinute
        self.takes = takes
    }

    public var isLearned: Bool { takes > 0 }

    /// "your pace" once learned, otherwise "a calm pace".
    public var label: String { isLearned ? "at your pace" : "at a calm pace" }

    /// Words a minute while talking, across the sentences of one take.
    /// Nil when the take has too few words to say.
    public static func measure(_ transcript: Transcript) -> Double? {
        let sentences = transcript.sentences()
        var words = 0
        var seconds = 0.0
        for sentence in sentences where sentence.wordIDs.count >= 3 {
            words += sentence.wordIDs.count
            seconds += sentence.duration
        }
        guard words >= 20, seconds > 3 else { return nil }
        return Double(words) / seconds * 60
    }

    /// The median of the takes' paces, clamped to something sane (90 to
    /// 220). Takes too short to measure are skipped.
    public static func learn(from transcripts: [Transcript]) -> SpeakingPace {
        let paces = transcripts.compactMap(measure).sorted()
        guard !paces.isEmpty else { return SpeakingPace() }
        let mid = paces.count / 2
        let median = paces.count % 2 == 0 ? (paces[mid - 1] + paces[mid]) / 2 : paces[mid]
        return SpeakingPace(wordsPerMinute: min(220, max(90, median.rounded())), takes: paces.count)
    }
}
