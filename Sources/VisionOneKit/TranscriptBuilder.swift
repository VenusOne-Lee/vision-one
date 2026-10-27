import Foundation

/// One piece of text from a speech engine with its timing. Parakeet gives
/// sub-word tokens ("▁hel", "lo", ","); WhisperKit gives whole words. The
/// builder turns either into a `Transcript`.
public struct RecognizedPiece: Equatable, Sendable {
    public var text: String
    /// Seconds from the start of the audio that was transcribed.
    public var start: Double
    public var end: Double
    public var confidence: Double?
    /// True when this piece begins a new word.
    public var startsWord: Bool

    public init(text: String, start: Double, end: Double, confidence: Double? = nil, startsWord: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.startsWord = startsWord
    }
}

/// Builds a valid transcript from engine output: joins pieces into words,
/// keeps punctuation on the word before it, tidies timings so words are
/// in order and never overlap, and splits words into sentence segments.
public enum TranscriptBuilder {
    /// A pause this long starts a new segment even mid-sentence.
    public static let segmentPause = 1.0
    /// Long run-ons are split so a paragraph stays readable.
    public static let maxSegmentWords = 40
    /// Shortest word the builder will write.
    static let minWordDuration = 0.02

    public static func build(
        pieces: [RecognizedPiece],
        language: String,
        engine: String,
        audioTrack: String = "mic",
        duration: Double,
        createdAt: Date = Date()
    ) -> Transcript {
        let words = tidy(join(pieces), duration: duration)
        return Transcript(language: language, engine: engine, audioTrack: audioTrack,
                          duration: duration, createdAt: createdAt, segments: segment(words))
    }

    private struct Draft {
        var text: String
        var start: Double
        var end: Double
        var confidences: [Double]
    }

    /// Pieces into words. A piece that is only punctuation sticks to the
    /// word before it, even when the engine marked it as a new word.
    private static func join(_ pieces: [RecognizedPiece]) -> [Draft] {
        var drafts: [Draft] = []
        for piece in pieces {
            let text = piece.text
                .replacingOccurrences(of: "▁", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let isPunctuation = text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }

            if var last = drafts.last, isPunctuation || !piece.startsWord {
                last.text += text
                if !isPunctuation { last.end = max(last.end, piece.end) }
                if let c = piece.confidence, !isPunctuation { last.confidences.append(c) }
                drafts[drafts.count - 1] = last
            } else {
                drafts.append(Draft(text: text, start: piece.start, end: piece.end,
                                    confidences: piece.confidence.map { [$0] } ?? []))
            }
        }
        return drafts
    }

    /// Clamps into the audio, keeps start times in order, gives every word
    /// a length, and trims overlaps so one word ends before the next starts.
    private static func tidy(_ drafts: [Draft], duration: Double) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        let latestStart = max(0, duration - minWordDuration)
        for draft in drafts {
            var start = min(max(0, draft.start), latestStart)
            if let previous = words.last {
                start = max(start, min(previous.start + minWordDuration, latestStart))
            }
            let end = min(max(draft.end, start + minWordDuration), max(duration, start + minWordDuration))

            if var previous = words.last, previous.end > start {
                previous.end = max(start, previous.start + minWordDuration)
                words[words.count - 1] = previous
            }
            let confidence = draft.confidences.isEmpty
                ? nil
                : draft.confidences.reduce(0, +) / Double(draft.confidences.count)
            words.append(TranscriptWord(id: words.count, text: draft.text, start: start, end: end,
                                        confidence: confidence))
        }
        return words
    }

    private static func segment(_ words: [TranscriptWord]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [TranscriptWord] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let next = index + 1 < words.count ? words[index + 1] : nil
            let endsSentence = word.text.last.map { ".?!…".contains($0) } ?? false
            let pauses = next.map { $0.start - word.end >= segmentPause } ?? true
            if endsSentence || pauses || current.count >= maxSegmentWords || next == nil {
                segments.append(TranscriptSegment(words: current))
                current = []
            }
        }
        return segments
    }
}
