import Foundation

/// "Cut where nobody's talking": the quiet parts of a take, found from
/// the mic levels when there are any, else from the gaps between words.
/// The Ask bar uses this, because the Editor agent only weighs whole
/// sentences and has nothing to say about silence.
public enum SilenceCut {
    /// True when an ask is about taking out silence: "cut the silence",
    /// "remove the pauses", "cut where you don't hear someone talking".
    public static func isSilenceAsk(_ ask: String) -> Bool {
        let text = ask.lowercased().replacingOccurrences(of: "’", with: "'")
        let phrases = [
            "silence", "silent", "quiet", "dead air", "pause", "gaps", "gap ", "dead space",
            "not talking", "no talking", "nobody talk", "no one talk", "noone talk", "nobody speak",
            "no one speak", "not speaking", "no speech", "don't hear", "dont hear", "can't hear",
            "nothing is said", "nothing said", "no voice",
        ]
        return phrases.contains { text.contains($0) } || text.hasSuffix(" gap")
    }

    /// The quiet stretches as cuts: silence at the very start and end goes
    /// (keeping `keptEdge`), and quiet inside the take is shortened to
    /// `keptPause`. Quiet runs are split around any word in them, so a
    /// soft word the mic barely caught still stays.
    /// - Parameters:
    ///   - duration: Length of screen.mov; quiet that runs to the end of
    ///     the sound runs on to here.
    public static func proposals(words: [TranscriptWord], duration: Double, loudness: LoudnessEnvelope?,
                                 settings: CleanupSettings = CleanupSettings()) -> [CutProposal] {
        guard duration > 0 else { return [] }
        let speech = words.map(\.span).sorted { $0.start < $1.start }
        var quiet: [TimeSpan]
        var soundEnd = duration
        if let loudness, !loudness.levels.isEmpty {
            soundEnd = min(duration, loudness.duration)
            quiet = loudness.silentSpans(minDuration: settings.minPause)
            // After the sound stops there's nothing to hear.
            if let last = quiet.last, last.end >= soundEnd - loudness.hop - 1e-9 {
                quiet[quiet.count - 1].end = duration
            } else if soundEnd < duration - settings.minPause {
                quiet.append(TimeSpan(start: soundEnd, end: duration))
            }
            quiet = quiet.flatMap { subtract(speech, from: $0, margin: settings.margin) }
        } else {
            guard !speech.isEmpty else { return [] }
            quiet = gaps(between: speech, duration: duration)
        }

        var cuts: [CutProposal] = []
        for span in quiet where span.duration >= settings.minPause {
            let atStart = span.start <= 1e-6
            let atEnd = span.end >= duration - 1e-6
            // Nothing to keep; never cut the whole take.
            if atStart && atEnd { continue }
            let cut: CutProposal
            if atStart {
                cut = CutProposal(start: 0, end: span.end - settings.keptEdge, reason: .deadAir)
            } else if atEnd {
                cut = CutProposal(start: span.start + settings.keptEdge, end: duration, reason: .deadAir)
            } else {
                let half = settings.keptPause / 2
                cut = CutProposal(start: span.start + half, end: span.end - half, reason: .pause)
            }
            if cut.duration >= settings.minCut { cuts.append(cut) }
        }
        return cuts
    }

    /// What the Ask bar did, in words for its status line.
    public struct Result: Equatable, Sendable {
        public var edits: EditList
        /// Quiet stretches cut by this ask.
        public var stretches: Int
        /// Seconds the video got shorter by.
        public var removedSeconds: Double
    }

    /// Cuts the quiet parts straight away: the user asked for it, so these
    /// arrive solid, and one undo brings them all back. Undecided silence
    /// suggestions are replaced by the fresh ones, which trust the mic.
    /// Silence the user turned down before stays turned down, unless
    /// they're asking now.
    public static func apply(_ proposals: [CutProposal], to edits: EditList) -> Result {
        var next = edits
        let silenceReasons: Set<String> = [Cut.Reason.pause, Cut.Reason.deadAir]
        next.cuts.removeAll { $0.state != .accepted && silenceReasons.contains($0.reason ?? "") }
        var stretches = 0
        for proposal in proposals {
            let span = TimeSpan(start: proposal.start, end: proposal.end)
            // Already gone: nothing new to cut here.
            if next.removedSpans.contains(where: { $0.start <= span.start + 1e-6 && span.end <= $0.end + 1e-6 }) {
                continue
            }
            if next.add(Cut(span: span, reason: proposal.reason.rawValue, state: .accepted)) != nil {
                stretches += 1
            }
        }
        let removed = max(0, edits.outputDuration - next.outputDuration)
        return Result(edits: next, stretches: stretches, removedSeconds: removed)
    }

    /// Undecided pause and dead-air suggestions swapped for `proposals`,
    /// still dashed. Used once a take gets its levels.json, so takes
    /// cleaned before silence was checked against the mic are fixed.
    public static func refreshSuggestions(_ edits: EditList, with proposals: [CutProposal]) -> EditList {
        var next = edits
        let silenceReasons: Set<String> = [Cut.Reason.pause, Cut.Reason.deadAir]
        next.cuts.removeAll { $0.state == .proposed && silenceReasons.contains($0.reason ?? "") }
        next.propose(proposals.filter { $0.reason == .pause || $0.reason == .deadAir })
        return next
    }

    // MARK: Helpers

    /// `span` with every word cut out of it, keeping `margin` beside each.
    static func subtract(_ words: [TimeSpan], from span: TimeSpan, margin: Double) -> [TimeSpan] {
        var pieces = [span]
        for word in words where word.overlaps(span) {
            let hole = TimeSpan(start: word.start - margin, end: word.end + margin)
            pieces = pieces.flatMap { piece -> [TimeSpan] in
                guard piece.overlaps(hole) else { return [piece] }
                var out: [TimeSpan] = []
                if hole.start > piece.start { out.append(TimeSpan(start: piece.start, end: hole.start)) }
                if hole.end < piece.end { out.append(TimeSpan(start: hole.end, end: piece.end)) }
                return out
            }
        }
        return pieces
    }

    /// The time before, between and after `words` (sorted).
    static func gaps(between words: [TimeSpan], duration: Double) -> [TimeSpan] {
        var out: [TimeSpan] = []
        var cursor = 0.0
        for word in words {
            if word.start > cursor { out.append(TimeSpan(start: cursor, end: word.start)) }
            cursor = max(cursor, word.end)
        }
        if duration > cursor { out.append(TimeSpan(start: cursor, end: duration)) }
        return out
    }
}
