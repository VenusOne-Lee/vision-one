import Foundation

/// Turns transcript words into caption cues on the edited timeline.
///
/// 1. Words the user cut are dropped and the rest are retimed with
///    `outputTime`: the editor passes EditList.outputTime(forSource:);
///    export passes its frame-snapped ExportTimeline.outputTime(forSource:),
///    so captions always match the cut that's rendered.
/// 2. Words are grouped into cues, breaking at sentence ends, at pauses,
///    and when the lines are full.
/// 3. Each cue is split into balanced lines and stretched to a readable
///    minimum (reading speed, and 0.5 s plus 0.3 s a word) without
///    running into the next cue.
public struct CaptionBuilder: Sendable {
    public var layout: CaptionLayout
    /// Product and brand names to mark as keywords, besides numbers.
    public var keywordNames: Set<String>
    /// Fix common mis-hearings of South African words (see MzansiLexicon).
    public var mzansiSpelling: Bool

    public init(layout: CaptionLayout, keywordNames: Set<String> = [], mzansiSpelling: Bool = true) {
        self.layout = layout
        self.keywordNames = Set(keywordNames.map { CaptionKeywords.normalised($0) })
        self.mzansiSpelling = mzansiSpelling
    }

    /// Builds cues. `outputTime` maps a source time to output time and
    /// returns nil for time inside a cut; leave it out for an uncut take.
    public func cues(
        for words: [CaptionWord],
        outputTime: (Double) -> Double? = { $0 }
    ) -> [CaptionCue] {
        let kept = retimed(marked(cleaned(words)), outputTime: outputTime)
        let groups = group(kept)
        var cues = groups.map { group -> CaptionCue in
            CaptionCue(start: group[0].start, end: group[group.count - 1].end, lines: lines(for: group))
        }
        stretch(&cues)
        return cues
    }

    // MARK: - Steps

    private func cleaned(_ words: [CaptionWord]) -> [CaptionWord] {
        words.compactMap { word in
            var word = word
            word.text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.text.isEmpty else { return nil }
            if mzansiSpelling { word.text = MzansiLexicon.fix(word.text) }
            return word
        }
    }

    private func marked(_ words: [CaptionWord]) -> [CaptionWord] {
        var result = words
        for i in result.indices {
            let startsSentence = i == 0 || Self.endsSentence(result[i - 1].text)
            if CaptionKeywords.isKeyword(result[i].text, startsSentence: startsSentence, names: keywordNames) {
                result[i].isKeyword = true
            }
        }
        return result
    }

    private func retimed(_ words: [CaptionWord], outputTime: (Double) -> Double?) -> [CaptionWord] {
        var result: [CaptionWord] = []
        for word in words {
            guard let start = outputTime(word.start) else { continue }
            let spoken = max(0.01, word.end - word.start)
            var end = outputTime(word.end) ?? start + spoken
            // A word whose end sits past a cut would otherwise stretch
            // over the jump.
            if end < start || end - start > spoken + 0.001 { end = start + spoken }
            var copy = word
            copy.start = start
            copy.end = end
            result.append(copy)
        }
        return result
    }

    private func group(_ words: [CaptionWord]) -> [[CaptionWord]] {
        var groups: [[CaptionWord]] = []
        var current: [CaptionWord] = []
        let capacity = layout.maxCharactersPerLine * layout.maxLines

        for word in words {
            if let last = current.last, shouldBreak(current, last: last, next: word, capacity: capacity) {
                groups.append(current)
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func shouldBreak(_ current: [CaptionWord], last: CaptionWord, next: CaptionWord, capacity: Int) -> Bool {
        if next.start - last.end >= layout.pauseBreak { return true }
        if Self.endsSentence(last.text) { return true }
        if let cap = layout.maxWordsPerCue, current.count >= cap { return true }
        if next.end - current[0].start > layout.maxDuration { return true }
        if splitLines(current + [next]) == nil { return true }
        // Prefer to end a cue at a comma once it is mostly full.
        if Self.endsClause(last.text), Self.length(current) >= capacity * 3 / 5 { return true }
        return false
    }

    /// Lines for a cue; falls back to one line per word that is too long
    /// to fit anywhere.
    private func lines(for words: [CaptionWord]) -> [[CaptionWord]] {
        splitLines(words) ?? [words]
    }

    /// Splits words into at most `maxLines` lines of at most
    /// `maxCharactersPerLine`, or nil when they don't fit. A single word
    /// always fits, however long.
    func splitLines(_ words: [CaptionWord]) -> [[CaptionWord]]? {
        let limit = layout.maxCharactersPerLine
        if words.count <= 1 || Self.length(words) <= limit { return [words] }
        if layout.maxLines == 1 { return nil }
        if layout.maxLines == 2 { return splitInTwo(words, limit: limit) }

        // More than two lines: fill greedily.
        var lines: [[CaptionWord]] = [[]]
        for word in words {
            if !lines[lines.count - 1].isEmpty, Self.length(lines[lines.count - 1] + [word]) > limit {
                lines.append([])
            }
            lines[lines.count - 1].append(word)
        }
        return lines.count <= layout.maxLines ? lines : nil
    }

    /// Picks the best place to break two lines: both must fit; then
    /// prefer a break after punctuation, before a conjunction (not after
    /// one), never after an article or preposition, lines of similar length, and a bottom
    /// line that is the longer one (a pyramid reads easier).
    private func splitInTwo(_ words: [CaptionWord], limit: Int) -> [[CaptionWord]]? {
        var best: (score: Double, index: Int)?
        for i in 1..<words.count {
            let top = Array(words[..<i])
            let bottom = Array(words[i...])
            let topLength = Self.length(top)
            let bottomLength = Self.length(bottom)
            guard topLength <= limit, bottomLength <= limit else { continue }

            var score = Double(abs(topLength - bottomLength))
            if bottomLength < topLength { score += 2 }
            let before = top[top.count - 1].text
            let after = CaptionKeywords.normalised(bottom[0].text)
            if Self.endsClause(before) || Self.endsSentence(before) { score -= 12 }
            if Self.breakBefore.contains(after) { score -= 6 }
            // A line that ends on "and" or "so" leaves the thought hanging.
            if Self.breakBefore.contains(CaptionKeywords.normalised(before)) { score += 6 }
            if Self.neverBreakAfter.contains(CaptionKeywords.normalised(before)) { score += 20 }
            if best == nil || score < best!.score { best = (score, i) }
        }
        guard let index = best?.index else { return nil }
        return [Array(words[..<index]), Array(words[index...])]
    }

    /// Stretches short cues to a readable length without overlapping the
    /// next cue, and keeps a small gap between cues.
    private func stretch(_ cues: inout [CaptionCue]) {
        for i in cues.indices {
            let cue = cues[i]
            let characters = Double(cue.text.count)
            let reading = max(characters / layout.maxCharactersPerSecond, layout.readingTime(words: cue.words.count))
            let wanted = min(layout.maxDuration, max(layout.minDuration, reading))
            var end = max(cue.end, cue.start + wanted)
            if i + 1 < cues.count {
                let limit = cues[i + 1].start - layout.gap
                if end > limit { end = max(cue.end, limit) }
                // Words never overlap, but keep the cue strictly before the next.
                end = min(end, cues[i + 1].start)
            }
            cues[i].end = max(end, cue.start + 0.01)
        }
    }

    // MARK: - Text helpers

    static func length(_ words: [CaptionWord]) -> Int {
        guard !words.isEmpty else { return 0 }
        return words.reduce(0) { $0 + $1.text.count } + words.count - 1
    }

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let last = trimmed.last else { return false }
        return ".?!…".contains(last)
    }

    static func endsClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ",;:–—".contains(last)
    }

    static let breakBefore: Set<String> = [
        "and", "but", "or", "so", "because", "that", "which", "who", "when", "while", "if", "then",
    ]

    static let neverBreakAfter: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "my", "your", "our", "this", "i",
    ]
}
