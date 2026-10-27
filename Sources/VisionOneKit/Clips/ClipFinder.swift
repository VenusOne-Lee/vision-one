import Foundation

/// Finds short clips in a take on the Mac, with no AI service: rung one
/// of the AI ladder. It splits the transcript into sentences, tries every
/// run of whole sentences that lasts between `minDuration` and
/// `maxDuration` once the editor's cuts are left out, scores each run,
/// and keeps the best ones that don't overlap. The Clipper agent can
/// take these same candidates and rescore and title them.
public struct ClipFinder: Sendable {
    public struct Options: Equatable, Sendable {
        public var minDuration: Double = 15
        public var maxDuration: Double = 60
        /// The length that scores best.
        public var targetDuration: Double = 35
        public var maxClips: Int = 5
        /// A silence this long ends a sentence even without a full stop.
        public var sentenceGap: Double = 0.8
        public var format: ClipFormat = .vertical

        public init() {}
    }

    /// A run of words the finder treats as one sentence.
    public struct Sentence: Equatable, Sendable {
        public let words: [TranscriptWord]
        public var start: Double { words.first?.start ?? 0 }
        public var end: Double { words.last?.end ?? 0 }
        public var text: String { words.map(\.text).joined(separator: " ") }
        public var endsCleanly: Bool {
            guard let last = words.last?.text.last else { return false }
            return ".?!".contains(last)
        }
        public var isQuestion: Bool { words.last?.text.hasSuffix("?") ?? false }
    }

    /// How a candidate scored, each part 0...1.
    public struct Score: Equatable, Sendable {
        public var hook: Double
        public var complete: Double
        public var pace: Double
        public var clean: Double
        public var length: Double

        public var total: Double {
            0.3 * hook + 0.25 * complete + 0.15 * pace + 0.15 * clean + 0.15 * length
        }

        /// The strongest reason, for the clip card.
        public var reason: String {
            let parts: [(Double, String)] = [
                (hook * 0.3, "strong opening"),
                (complete * 0.25, "a complete thought"),
                (pace * 0.15, "good pace"),
                (clean * 0.15, "few fillers"),
                (length * 0.15, "a good length"),
            ]
            return parts.max { $0.0 < $1.0 }?.1 ?? ""
        }
    }

    public struct Candidate: Equatable, Sendable {
        public let span: TimeSpan
        public let sentences: [Sentence]
        /// Length once the editor's cuts are left out.
        public let duration: Double
        public let score: Score
    }

    public var options: Options
    public var lexicon: FillerLexicon

    public init(options: Options = Options(), lexicon: FillerLexicon = .standard) {
        self.options = options
        self.lexicon = lexicon
    }

    /// Openers that tend to hook a viewer in the first second.
    static let hookOpeners: [[String]] = [
        ["here's"], ["here", "is"], ["how"], ["why"], ["what"], ["stop"], ["never"], ["don't"],
        ["the", "secret"], ["the", "trick"], ["this", "is"], ["if", "you"], ["you"], ["imagine"],
        ["the", "fastest"], ["the", "easiest"], ["the", "best"], ["the", "one"],
    ]

    /// Words that only make sense after something else was said.
    static let danglingOpeners: Set<String> = ["and", "but", "so", "because", "or", "also", "then", "which"]

    // MARK: Finding

    /// The best clips, best first, as proposed clips ready for
    /// `ClipList.propose`. Clips already in `existing` are avoided.
    public func clips(transcript: Transcript, edits: EditList, existing: [Clip] = []) -> [Clip] {
        let picks = best(candidates(transcript: transcript, edits: edits), avoiding: existing.map(\.span))
        return picks.map { candidate in
            Clip(title: Self.title(for: candidate.sentences.first?.words ?? [], lexicon: lexicon),
                 hook: candidate.sentences.first?.text,
                 span: candidate.span,
                 score: candidate.score.total,
                 reason: candidate.score.reason,
                 origin: Clip.Origin.auto,
                 state: .proposed,
                 format: options.format)
        }
    }

    /// Every run of whole sentences within the length limits, scored.
    public func candidates(transcript: Transcript, edits: EditList) -> [Candidate] {
        let sentences = self.sentences(transcript: transcript, edits: edits)
        var result: [Candidate] = []
        for i in sentences.indices {
            var j = i
            while j < sentences.count {
                let span = TimeSpan(start: sentences[i].start, end: sentences[j].end)
                let duration = keptDuration(span, edits: edits)
                if duration > options.maxDuration { break }
                if duration >= options.minDuration {
                    let run = Array(sentences[i...j])
                    result.append(Candidate(span: span, sentences: run, duration: duration,
                                            score: score(run, duration: duration)))
                }
                j += 1
            }
        }
        return result
    }

    /// Highest scores first, skipping anything that overlaps a pick or a
    /// span in `avoiding`.
    public func best(_ candidates: [Candidate], avoiding: [TimeSpan] = []) -> [Candidate] {
        var taken = avoiding
        var picks: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.score.total > $1.score.total }) {
            guard picks.count < options.maxClips else { break }
            guard !taken.contains(where: { $0.overlaps(candidate.span) }) else { continue }
            picks.append(candidate)
            taken.append(candidate.span)
        }
        return picks
    }

    /// Words the editor kept, grouped into sentences at full stops,
    /// question marks, exclamation marks and long silences.
    public func sentences(transcript: Transcript, edits: EditList) -> [Sentence] {
        let words = transcript.words.filter { !edits.isRemoved(($0.start + $0.end) / 2) }
        var sentences: [Sentence] = []
        var current: [TranscriptWord] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let next = index + 1 < words.count ? words[index + 1] : nil
            let punctuated = word.text.last.map { ".?!".contains($0) } ?? false
            let paused = next.map { $0.start - word.end >= options.sentenceGap } ?? true
            if punctuated || paused {
                sentences.append(Sentence(words: current))
                current = []
            }
        }
        if !current.isEmpty { sentences.append(Sentence(words: current)) }
        return sentences
    }

    // MARK: Scoring

    func score(_ run: [Sentence], duration: Double) -> Score {
        let words = run.flatMap(\.words)
        let first = run.first
        let normalized = (first?.words ?? []).map { FillerLexicon.normalize($0.text) }

        // Hook: a question, a strong opener, or a number up front.
        var hook = 0.2
        if first?.isQuestion == true { hook += 0.4 }
        if Self.hookOpeners.contains(where: { normalized.starts(with: $0) }) { hook += 0.3 }
        if first?.text.contains(where: \.isNumber) == true { hook += 0.2 }
        if let opener = normalized.first, Self.danglingOpeners.contains(opener) { hook -= 0.2 }

        // Complete: ends on a full stop and doesn't start mid-thought.
        var complete = run.last?.endsCleanly == true ? 1.0 : 0.4
        if let opener = normalized.first, Self.danglingOpeners.contains(opener) { complete -= 0.4 }

        // Pace: about 2.3 to 3.6 words a second reads well on a phone.
        let rate = duration > 0 ? Double(words.count) / duration : 0
        let pace: Double
        switch rate {
        case 2.3...3.6: pace = 1
        case ..<2.3: pace = max(0, (rate - 1) / 1.3)
        default: pace = max(0, (5 - rate) / 1.4)
        }

        // Clean: few fillers left in.
        let fillers = words.filter { word in
            let n = FillerLexicon.normalize(word.text)
            return FillerLexicon.isHesitation(n)
        }.count
        let clean = words.isEmpty ? 0 : max(0, 1 - Double(fillers) / Double(words.count) * 8)

        // Length: closest to the target scores best.
        let target = max(options.targetDuration, 1)
        let length = max(0, 1 - abs(duration - target) / target)

        func unit(_ v: Double) -> Double { min(max(v, 0), 1) }
        return Score(hook: unit(hook), complete: unit(complete), pace: unit(pace),
                     clean: unit(clean), length: unit(length))
    }

    /// The span's length with the editor's accepted cuts left out.
    func keptDuration(_ span: TimeSpan, edits: EditList) -> Double {
        edits.keptSpans.reduce(0) { total, kept in
            total + max(0, min(kept.end, span.end) - max(kept.start, span.start))
        }
    }

    /// A short title from the opening sentence: hesitations dropped, at
    /// most seven words, a capital first letter, no trailing full stop.
    public static func title(for words: [TranscriptWord], lexicon: FillerLexicon = .standard, maxWords: Int = 7) -> String {
        let kept = words.filter { !FillerLexicon.isHesitation(FillerLexicon.normalize($0.text)) }
        var parts = kept.prefix(maxWords).map(\.text)
        guard !parts.isEmpty else { return "Clip" }
        let truncated = kept.count > maxWords
        if var last = parts.popLast() {
            while let c = last.last, ".,;:!".contains(c) { last.removeLast() }
            if !last.isEmpty { parts.append(last) }
        }
        var title = parts.joined(separator: " ")
        if let first = title.first { title = first.uppercased() + title.dropFirst() }
        return truncated && !title.hasSuffix("?") ? title + "…" : title
    }
}
