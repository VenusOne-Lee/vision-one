import Foundation

/// Suggests sound effects from the Energy dial. Calm suggests none.
/// Lively puts a whoosh on each new topic (a pause of 1.2 s or more
/// before it, measured in the recording, so it still counts after
/// auto-clean shortens the pause), at most one every 25 seconds. Viral
/// adds a pop on the first word and allows one every 8 seconds.
/// Suggestions are dashed until accepted.
public enum EffectSuggester {
    /// Seconds of silence before a word that mark a new topic.
    public static let topicPause = 1.2
    /// A whoosh starts this early so its peak meets the word.
    public static let whooshLead = 0.25

    public static func minimumSpacing(for energy: Energy) -> Double? {
        switch energy {
        case .calm: return nil
        case .lively: return 25
        case .viral: return 8
        }
    }

    /// - Parameter words: word spans in take seconds, in order.
    public static func suggestions(energy: Energy, words: [TimeSpan], edits: EditList) -> [PlacedEffect] {
        guard let spacing = minimumSpacing(for: energy) else { return [] }
        let sorted = words.sorted { $0.start < $1.start }
        var out: [PlacedEffect] = []

        // The first word that plays.
        guard let firstIndex = sorted.firstIndex(where: { edits.outputTime(forSource: $0.start) != nil }) else { return [] }
        if energy == .viral {
            out.append(PlacedEffect(soundID: "pop", at: sorted[firstIndex].start, state: .proposed, isManual: false))
        }

        var lastOutput = edits.outputTime(forSource: sorted[firstIndex].start) ?? 0
        for i in sorted.indices where i > firstIndex {
            let word = sorted[i]
            guard word.start - sorted[i - 1].end >= topicPause,
                  let output = edits.outputTime(forSource: word.start),
                  output - lastOutput >= spacing else { continue }
            let at = edits.sourceTime(forOutput: max(0, output - whooshLead))
            out.append(PlacedEffect(soundID: "whoosh", at: at, state: .proposed, isManual: false))
            lastOutput = output
        }
        return out
    }
}

extension SoundPlan {
    /// Turns the Energy dial: drops the old suggestions and adds new ones.
    /// Accepted, rejected and hand-placed effects stay, and no suggestion
    /// lands within 1.5 seconds of one of them.
    public mutating func setEnergy(_ energy: Energy, words: [TimeSpan], edits: EditList) {
        self.energy = energy
        effects.removeAll { $0.state == .proposed && !$0.isManual }
        let kept = effects
        for suggestion in EffectSuggester.suggestions(energy: energy, words: words, edits: edits)
        where !kept.contains(where: { abs($0.at - suggestion.at) < 1.5 }) {
            effects.append(suggestion)
        }
    }
}
