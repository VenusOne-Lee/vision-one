import Foundation

/// A cut the cleanup pass proposes. It is drawn dashed until the user
/// accepts it.
public struct CutProposal: Equatable, Sendable {
    /// Raw values match the edit list's cut reasons.
    public enum Reason: String, Sendable {
        case filler
        case repeated = "repeat"
        case pause
        case deadAir

        /// When cuts merge, the one that tells the user most wins.
        var priority: Int {
            switch self {
            case .filler: return 3
            case .repeated: return 2
            case .deadAir: return 1
            case .pause: return 0
            }
        }
    }

    public var start: Double
    public var end: Double
    public var reason: Reason
    /// Ids of the words this cut removes. Empty for pauses.
    public var wordIDs: [Int]

    public init(start: Double, end: Double, reason: Reason, wordIDs: [Int] = []) {
        self.start = start
        self.end = end
        self.reason = reason
        self.wordIDs = wordIDs
    }

    public var duration: Double { end - start }

    /// The cut to put in the edit list, drawn dashed until accepted.
    public var cut: Cut {
        Cut(span: TimeSpan(start: start, end: end), reason: reason.rawValue, state: .proposed)
    }
}

extension EditList {
    /// Adds cleanup proposals, skipping any that overlap a cut already in
    /// the list, including ones the user rejected. Returns what was added.
    @discardableResult
    public mutating func propose(_ proposals: [CutProposal]) -> [Cut] {
        propose(proposals.map(\.cut))
    }
}

public struct CleanupSettings: Equatable, Sendable {
    /// Gaps between words at least this long are long pauses.
    public var minPause: Double = 1.0
    /// A long pause is shortened to this, not removed.
    public var keptPause: Double = 0.4
    /// Silence kept before the first word and after the last.
    public var keptEdge: Double = 0.25
    /// Room left next to a word that stays, so its tail isn't clipped.
    public var margin: Double = 0.05
    /// Propose "maybe" fillers (like, so, ja) when they stand alone.
    public var maybeFillers = true
    /// A gap this long counts as a boundary for a standalone filler.
    public var standaloneGap: Double = 0.15
    /// Propose cutting stutters ("the the").
    public var repeats = true
    /// Words that are often doubled on purpose.
    public var allowedRepeats: Set<String> = ["that", "had", "is", "very", "really", "no", "bye", "so", "ha", "knock", "now"]
    /// Cuts shorter than this are dropped.
    public var minCut: Double = 0.05

    public init() {}
}

/// Finds fillers, repeated words and long pauses in a word-timed
/// transcript, and proposes cuts for them. Plain logic: the app feeds it
/// the transcript (and the mic loudness when it has it) and writes the
/// proposals into the edit list.
public struct CleanupDetector: Sendable {
    public var settings: CleanupSettings
    public var lexicon: FillerLexicon

    public init(settings: CleanupSettings = CleanupSettings(), lexicon: FillerLexicon = .standard) {
        self.settings = settings
        self.lexicon = lexicon
    }

    /// Every proposal for a take's transcript.
    public func proposals(for transcript: Transcript, loudness: LoudnessEnvelope? = nil) -> [CutProposal] {
        proposals(for: transcript.words, duration: transcript.duration, loudness: loudness)
    }

    /// Every proposal for a list of words, sorted and merged where they touch.
    /// - Parameters:
    ///   - duration: Length of screen.mov, to trim dead air at the end.
    ///   - loudness: Mic levels. When given, pauses are only cut where
    ///     the audio is actually quiet.
    public func proposals(for words: [TranscriptWord], duration: Double? = nil, loudness: LoudnessEnvelope? = nil) -> [CutProposal] {
        var cuts: [CutProposal] = []
        var used = Set<Int>()
        for cut in fillers(in: words) {
            cuts.append(cut)
            used.formUnion(cut.wordIDs)
        }
        if settings.repeats {
            cuts += repeats(in: words, skipping: used)
        }
        cuts += pauses(in: words, duration: duration, loudness: loudness)
        return merge(cuts, words: words)
    }

    // MARK: Fillers

    public func fillers(in words: [TranscriptWord]) -> [CutProposal] {
        let normalized = words.map { FillerLexicon.normalize($0.text) }
        let entries = lexicon.entriesLongestFirst
        var cuts: [CutProposal] = []
        var i = 0
        while i < words.count {
            if FillerLexicon.isHesitation(normalized[i]) {
                cuts.append(wordCut(words, i...i, reason: .filler))
                i += 1
                continue
            }
            guard let entry = entries.first(where: { matches($0, normalized, at: i) }) else {
                i += 1
                continue
            }
            let range = i...(i + entry.tokens.count - 1)
            let propose = entry.strength == .sure
                || (settings.maybeFillers && standsAlone(range, in: words, position: entry.position))
            if propose {
                cuts.append(wordCut(words, range, reason: .filler))
                i = range.upperBound + 1
            } else {
                i += 1
            }
        }
        return cuts
    }

    private func matches(_ entry: FillerEntry, _ normalized: [String], at i: Int) -> Bool {
        guard i + entry.tokens.count <= normalized.count else { return false }
        if entry.tokens.count == 1 {
            // "yohhh", "haaai"
            return FillerLexicon.collapse(normalized[i]) == FillerLexicon.collapse(entry.tokens[0])
        }
        return zip(entry.tokens, normalized[i...]).allSatisfy { $0.0 == $0.1 }
    }

    private func standsAlone(_ range: ClosedRange<Int>, in words: [TranscriptWord], position: FillerEntry.Position) -> Bool {
        let first = range.lowerBound, last = range.upperBound
        let gapBefore = first > 0 ? words[first].start - words[first - 1].end : .infinity
        let gapAfter = last + 1 < words.count ? words[last + 1].start - words[last].end : .infinity
        // Punctuation inside a phrase ("you, know") means it isn't one.
        if range.dropLast().contains(where: { Self.endsWithPunctuation(words[$0].text) }) { return false }

        switch position {
        case .anywhere:
            let before = first == 0 || Self.endsWithPunctuation(words[first - 1].text) || gapBefore >= settings.standaloneGap
            let after = Self.endsWithPunctuation(words[last].text) || gapAfter >= settings.standaloneGap
            return before && after
        case .endOfSentence:
            guard first > 0, !Self.endsSentence(words[first - 1].text) else { return false }
            let before = Self.endsWithPunctuation(words[first - 1].text) || gapBefore >= settings.standaloneGap
            let after = Self.endsSentence(words[last].text) || gapAfter >= settings.standaloneGap * 2
            return before && after
        }
    }

    // MARK: Repeats

    /// "I I I think" proposes cutting the first two, keeping the last.
    public func repeats(in words: [TranscriptWord], skipping used: Set<Int> = []) -> [CutProposal] {
        let normalized = words.map { FillerLexicon.normalize($0.text) }
        var cuts: [CutProposal] = []
        var i = 0
        while i < words.count - 1 {
            var last = i
            while last + 1 < words.count, isRepeat(words, normalized, last, last + 1, used) {
                last += 1
            }
            if last > i {
                cuts.append(wordCut(words, i...(last - 1), reason: .repeated))
                i = last + 1
            } else {
                i += 1
            }
        }
        return cuts
    }

    private func isRepeat(_ words: [TranscriptWord], _ normalized: [String], _ a: Int, _ b: Int, _ used: Set<Int>) -> Bool {
        let word = normalized[a]
        return !word.isEmpty
            && word == normalized[b]
            && !used.contains(words[a].id) && !used.contains(words[b].id)
            && !settings.allowedRepeats.contains(word)
            && Double(word) == nil
            && !Self.endsSentence(words[a].text)
            && words[b].start - words[a].end < settings.minPause
    }

    // MARK: Pauses

    public func pauses(in words: [TranscriptWord], duration: Double? = nil, loudness: LoudnessEnvelope? = nil) -> [CutProposal] {
        guard let first = words.first, let last = words.last else { return [] }
        let silent = loudness?.silentSpans(minDuration: settings.minPause)
        var cuts: [CutProposal] = []

        // Dead air before the first word and after the last.
        let leadEnd = first.start - settings.keptEdge
        if leadEnd >= settings.minCut {
            cuts.append(CutProposal(start: 0, end: leadEnd, reason: .deadAir))
        }
        if let duration, duration - (last.end + settings.keptEdge) >= settings.minCut {
            cuts.append(CutProposal(start: last.end + settings.keptEdge, end: duration, reason: .deadAir))
        }

        for (a, b) in zip(words, words.dropFirst()) {
            var gap = TimeSpan(start: a.end, end: b.start)
            guard gap.duration >= settings.minPause else { continue }
            if let silent {
                // Trust the audio over the word times: cut only the
                // longest quiet run inside the gap.
                let quiet = silent.compactMap { s -> TimeSpan? in
                    let start = max(s.start, gap.start), end = min(s.end, gap.end)
                    return end > start ? TimeSpan(start: start, end: end) : nil
                }
                guard let longest = quiet.max(by: { $0.duration < $1.duration }),
                      longest.duration >= settings.minPause else { continue }
                gap = longest
            }
            let half = settings.keptPause / 2
            if gap.duration - settings.keptPause >= settings.minCut {
                cuts.append(CutProposal(start: gap.start + half, end: gap.end - half, reason: .pause))
            }
        }
        return cuts.sorted { $0.start < $1.start }
    }

    // MARK: Helpers

    /// Cuts words from the start of the first through a short gap after
    /// the last, keeping `margin` before the next word. The gap before
    /// stays, so "I was, um, going" closes up to "I was, going". A long
    /// gap after is left to the pause pass, which shortens it instead of
    /// removing it, so a filler cut never swallows a pause.
    private func wordCut(_ words: [TranscriptWord], _ range: ClosedRange<Int>, reason: CutProposal.Reason) -> CutProposal {
        let first = words[range.lowerBound], last = words[range.upperBound]
        let start = first.start
        var end = last.end
        if range.upperBound + 1 < words.count {
            let next = words[range.upperBound + 1].start
            let gap = next - last.end
            if gap < settings.minPause {
                end = max(last.end, next - min(settings.margin, gap))
            }
        }
        return CutProposal(start: start, end: end, reason: reason, wordIDs: words[range].map(\.id))
    }

    /// Sorts cuts and joins ones that overlap or touch. Cuts less than
    /// `margin` apart join too ("Ja, um," is one cut, not two with a
    /// sliver of silence between), unless a word sits in between.
    public func merge(_ cuts: [CutProposal], words: [TranscriptWord] = []) -> [CutProposal] {
        var out: [CutProposal] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) where cut.duration >= settings.minCut {
            if var last = out.last, cut.start <= last.end + settings.margin + 1e-6,
               !words.contains(where: { $0.start >= last.end && $0.end <= cut.start }) {
                last.end = max(last.end, cut.end)
                if cut.reason.priority > last.reason.priority { last.reason = cut.reason }
                let existing = last.wordIDs
                last.wordIDs += cut.wordIDs.filter { !existing.contains($0) }
                out[out.count - 1] = last
            } else {
                out.append(cut)
            }
        }
        return out
    }

    static func endsWithPunctuation(_ text: String) -> Bool {
        guard let ch = text.last else { return false }
        return ",;:.!?…—–-".contains(ch)
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let ch = text.last else { return false }
        return ".!?…".contains(ch)
    }
}
