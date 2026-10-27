import Foundation

/// Follows a voice through a script, word by word. Used live by the
/// teleprompter (fed from on-device speech recognition) and after the
/// take by the best-take picker (fed from the transcript), so both agree
/// on where each word belongs.
///
/// Speaking in order moves forward, small skips are allowed, and saying
/// the start of a line again jumps back to it: that's a retake.
public struct ScriptFollower: Equatable, Sendable {
    public let words: [ScriptWord]
    /// Index of the next word expected.
    public private(set) var position = 0
    /// The last few words heard, normalized, for context.
    private var recent: [String] = []

    /// How far ahead a missed word or two can be skipped.
    static let skipAhead = 3
    /// How far back and ahead to look when the voice isn't where expected.
    static let lookBack = 60
    static let lookAhead = 15
    /// Words too common to move the prompter on their own.
    static let common: Set<String> = ["the", "a", "an", "and", "to", "of", "in", "it", "is", "you", "i", "on",
                                      "for", "with", "that", "this", "your", "we", "be", "at", "or", "so"]

    public init(script: Script) {
        words = script.words
    }

    public var isFinished: Bool { position >= words.count }

    /// The line being read now (the line of the next expected word).
    public var currentLine: Int? {
        guard !words.isEmpty else { return nil }
        return words[min(position, words.count - 1)].line
    }

    /// Feeds one heard word. Returns the index of the script word it
    /// matched, or nil when it matched nothing (an "um", an aside).
    @discardableResult
    public mutating func hear(_ spoken: String) -> Int? {
        let word = Script.normalize(spoken)
        guard !word.isEmpty else { return nil }
        recent.append(word)
        if recent.count > 4 { recent.removeFirst() }

        // In order, or a missed word or two.
        for offset in 0..<Self.skipAhead where position + offset < words.count {
            if words[position + offset].text == word {
                // A common word only skips ahead if it's the very next one.
                if offset > 0, Self.common.contains(word) { break }
                position += offset + 1
                return position - 1
            }
        }

        // Elsewhere: back for a retake, or further on. The longer the run
        // of recent words that matches, the surer the jump.
        let low = max(0, position - Self.lookBack)
        let high = min(words.count - 1, position + Self.lookAhead)
        guard low <= high else { return nil }
        var best: (index: Int, run: Int, distance: Int)?
        for index in low...high where words[index].text == word {
            let run = matchedRun(endingAt: index)
            let startsLine = words[index].index == 0
            // One word is enough only to restart a line on a word that
            // means something; otherwise two in a row.
            let enough = run >= 2 || (startsLine && !Self.common.contains(word))
            guard enough else { continue }
            let distance = abs(index - position)
            if best == nil || run > best!.run || (run == best!.run && distance < best!.distance) {
                best = (index, run, distance)
            }
        }
        guard let best else { return nil }
        position = best.index + 1
        return best.index
    }

    /// How many of the recent words, newest first, line up with the
    /// script ending at `index`.
    private func matchedRun(endingAt index: Int) -> Int {
        var run = 0
        for (back, heard) in recent.reversed().enumerated() {
            let i = index - back
            guard i >= 0, words[i].text == heard else { break }
            run += 1
        }
        return run
    }

    /// Back to the start, for a restarted take.
    public mutating func reset() {
        position = 0
        recent = []
    }
}
