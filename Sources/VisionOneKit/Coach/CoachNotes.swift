import Foundation

/// How one script line went in a practice run.
public struct LineDelivery: Equatable, Sendable, Identifiable {
    public var id: Int { line }
    public var line: Int
    /// Heard words matched to this line (hesitations not included).
    public var words: [HeardWord]
    public var ums: [HeardWord]
    public var start: Double?
    public var end: Double?
    /// Words a minute while saying the line, when there's enough to tell.
    public var pace: Double?
    /// Pitch spread in semitones; small means flat.
    public var pitchSpread: Double?
    /// Silence before the line began, after the line before it ended.
    public var pauseBefore: Double?

    public var wasSaid: Bool { !words.isEmpty }
}

/// One of the coach's notes after a run. Tied to a moment so it can play
/// that bit back.
public struct CoachNote: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case tooFast, tooSlow, ums, longPause, flat, skipped
        case strongOpening, strongEnding, goodPace
    }

    public var id: String { "\(kind.rawValue)-\(line ?? -1)" }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var line: Int?
    /// Seconds into the run, for "play it back".
    public var time: Double
    public var isStrength: Bool
    /// How much it matters, for picking the top notes.
    var weight: Double
}

/// The coach's read of a practice run: per-line delivery and three notes.
public struct RehearsalReview: Equatable, Sendable {
    public var lines: [LineDelivery]
    public var notes: [CoachNote]
    public var overall: MeterReading
    public var duration: Double

    /// The line to "run again" first: the one the top fix is about.
    public var focusLine: Int? { notes.first { !$0.isStrength }?.line }
}

/// Turns a practice run into three short notes, never a report card: at
/// most two things to fix and one thing to keep. Plain rules on the Mac.
/// "Talk it through" hands these to the ElevenLabs coach as context.
public enum CoachNotes {
    public static let maxNotes = 3

    public static func review(script: Script, words: [HeardWord], frames: [VoiceFrame],
                              targets: RehearsalTargets = RehearsalTargets()) -> RehearsalReview {
        let lines = deliveries(script: script, words: words, frames: frames)
        let duration = max(words.last?.end ?? 0, frames.last?.time ?? 0)
        var monitor = RehearsalMonitor()
        monitor.setWords(words)
        for frame in frames { monitor.add(frame) }
        var overall = monitor.reading(at: duration)
        overall.pace = overallPace(words)
        overall.energy = RehearsalMonitor.energy(frames)
        let notes = pick(candidates(script: script, lines: lines, targets: targets, overall: overall))
        return RehearsalReview(lines: lines, notes: notes, overall: overall, duration: duration)
    }

    /// Words matched to lines with the same follower the teleprompter uses,
    /// so a retake of a line counts toward that line.
    public static func deliveries(script: Script, words: [HeardWord], frames: [VoiceFrame]) -> [LineDelivery] {
        var follower = ScriptFollower(script: script)
        var said: [Int: [HeardWord]] = [:]
        var ums: [Int: [HeardWord]] = [:]
        for word in words.sorted(by: { $0.start < $1.start }) {
            if word.isHesitation {
                if let line = follower.currentLine { ums[line, default: []].append(word) }
                continue
            }
            if let index = follower.hear(word.text) {
                said[follower.words[index].line, default: []].append(word)
            }
        }
        var result: [LineDelivery] = []
        var previousEnd: Double?
        for line in script.lines {
            let heard = said[line.id] ?? []
            let start = heard.first?.start, end = heard.last?.end
            var pace: Double?
            if let start, let end, heard.count >= 4, end - start > 1.2 {
                pace = Double(heard.count) / (end - start) * 60
            }
            var spread: Double?
            if let start, let end {
                spread = RehearsalMonitor.pitchSpread(frames.filter { $0.time >= start && $0.time <= end })
            }
            var pauseBefore: Double?
            if let start, let previousEnd { pauseBefore = max(0, start - previousEnd) }
            result.append(LineDelivery(line: line.id, words: heard, ums: ums[line.id] ?? [], start: start, end: end,
                                       pace: pace, pitchSpread: spread, pauseBefore: pauseBefore))
            if let end { previousEnd = end }
        }
        return result
    }

    static func overallPace(_ words: [HeardWord]) -> Double? {
        let spoken = words.filter { !$0.isHesitation }
        guard spoken.count >= 6, let first = spoken.first, let last = spoken.last, last.end - first.start > 2 else { return nil }
        // Pauses over a second are breaks, not speaking.
        let breaks = zip(spoken, spoken.dropFirst()).map { $1.start - $0.end }.filter { $0 > 1 }.reduce(0, +)
        return Double(spoken.count) / max(1, last.end - first.start - breaks) * 60
    }

    static func candidates(script: Script, lines: [LineDelivery], targets: RehearsalTargets,
                           overall: MeterReading) -> [CoachNote] {
        var notes: [CoachNote] = []
        let scriptLines = script.lines
        let lastSaid = lines.last(where: \.wasSaid)?.line ?? -1
        for delivery in lines {
            guard let scriptLine = scriptLines.first(where: { $0.id == delivery.line }) else { continue }
            let name = handle(for: scriptLine, index: delivery.line, count: scriptLines.count)
            let at = delivery.start ?? 0

            if !delivery.wasSaid, delivery.line < lastSaid {
                notes.append(CoachNote(kind: .skipped, title: "You skipped \(name)",
                                       detail: "Run it again, or take it out of the script if you don't need it.",
                                       line: delivery.line, time: at, isStrength: false, weight: 5))
                continue
            }
            if let pace = delivery.pace, pace > targets.pace.upperBound + 10 {
                let tail = lastWords(of: scriptLine.text, count: 4)
                notes.append(CoachNote(kind: .tooFast, title: "Slow down on \(name)",
                                       detail: "You hit \(Int(pace.rounded())) words a minute there. Try a beat before “\(tail)”.",
                                       line: delivery.line, time: at, isStrength: false,
                                       weight: 3 + (pace - targets.pace.upperBound) / 20))
            } else if let pace = delivery.pace, pace < targets.pace.lowerBound - 20 {
                notes.append(CoachNote(kind: .tooSlow, title: "Pick up \(name)",
                                       detail: "\(Int(pace.rounded())) words a minute. Shorter gaps between words will help.",
                                       line: delivery.line, time: at, isStrength: false,
                                       weight: 2 + (targets.pace.lowerBound - pace) / 30))
            }
            if !delivery.ums.isEmpty {
                let count = delivery.ums.count
                let first = delivery.ums[0]
                let where_ = delivery.line == 0 ? "in the opening" : "on \(name)"
                let early = delivery.start.map { first.start <= $0 + 0.6 } ?? true
                notes.append(CoachNote(kind: .ums, title: "\(count == 1 ? "One um" : "\(count) ums"), \(where_)",
                                       detail: "“\(context(of: first, in: lines))”. " + (early ? "Start the line a breath later."
                                                                                             : "Pause instead of filling the gap."),
                                       line: delivery.line, time: max(0, first.start - 1), isStrength: false,
                                       weight: 2 + Double(count)))
            }
            if let gap = delivery.pauseBefore, gap > 2 {
                notes.append(CoachNote(kind: .longPause, title: "Long pause before \(name)",
                                       detail: String(format: "%.1f s. The prompter follows your voice, so a glance is enough.", gap),
                                       line: delivery.line, time: max(0, at - gap), isStrength: false, weight: 2))
            }
            if let spread = delivery.pitchSpread, spread < 1.3, delivery.words.count >= 6 {
                let word = keyWord(in: scriptLine) ?? "the key word"
                notes.append(CoachNote(kind: .flat, title: "Lift \(name)",
                                       detail: "Your voice stayed flat there. Lean on one word, like “\(word)”.",
                                       line: delivery.line, time: at, isStrength: false, weight: 1.5))
            }
        }

        // Things to keep.
        func clean(_ d: LineDelivery?) -> Bool {
            guard let d, d.wasSaid, d.ums.isEmpty else { return false }
            if let pace = d.pace, pace > targets.pace.upperBound + 10 { return false }
            if let spread = d.pitchSpread, spread < 1.3 { return false }
            return true
        }
        if lines.count >= 2, clean(lines.last) {
            notes.append(CoachNote(kind: .strongEnding, title: "Strong ending",
                                   detail: ScriptCoach.endsOnAsk(scriptLines.last?.text ?? "") ? "Clear ask, good energy. Keep it." : "You finished clean. Keep it.",
                                   line: lines.last?.line, time: lines.last?.start ?? 0, isStrength: true, weight: 1))
        }
        if clean(lines.first) {
            notes.append(CoachNote(kind: .strongOpening, title: "Strong opening",
                                   detail: "Straight in, no warm-up. Keep it.",
                                   line: lines.first?.line, time: lines.first?.start ?? 0, isStrength: true, weight: 0.9))
        }
        if let pace = overall.pace, targets.pace.contains(pace) {
            notes.append(CoachNote(kind: .goodPace, title: "Good pace",
                                   detail: "\(Int(pace.rounded())) words a minute overall, easy to follow.",
                                   line: nil, time: 0, isStrength: true, weight: 0.8))
        }
        return notes
    }

    /// Two fixes at most, then one thing to keep; fill up with more of
    /// what went well when there's little to fix.
    static func pick(_ candidates: [CoachNote]) -> [CoachNote] {
        var fixes = candidates.filter { !$0.isStrength }.sorted { $0.weight > $1.weight }
        // One note per line: the weightiest.
        var seen = Set<Int>()
        fixes = fixes.filter { note in
            guard let line = note.line else { return true }
            return seen.insert(line).inserted
        }
        let strengths = candidates.filter(\.isStrength).sorted { $0.weight > $1.weight }
        var picked = Array(fixes.prefix(2))
        picked += strengths.prefix(maxNotes - picked.count)
        return picked
    }

    /// "the opening", "the ending", or "the SnapScan line": the line's most
    /// distinctive word, as written.
    static func handle(for line: ScriptLine, index: Int, count: Int) -> String {
        if let word = keyWord(in: line) { return "the \(word) line" }
        if index == 0 { return "the opening" }
        if index == count - 1 { return "the ending" }
        return "line \(index + 1)"
    }

    /// The longest word that isn't a common one, keeping its capitals.
    static func keyWord(in line: ScriptLine) -> String? {
        let raw = line.text.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        let candidates = raw.filter { word in
            let n = Script.normalize(word)
            return n.count >= 4 && !ScriptCoach.stopWords.contains(n) && !ScriptFollower.common.contains(n)
        }
        // Prefer names (a capital not at the start), then length.
        return candidates.enumerated().max { a, b in
            let aName = a.offset > 0 && a.element.first?.isUppercase == true
            let bName = b.offset > 0 && b.element.first?.isUppercase == true
            if aName != bName { return !aName }
            return a.element.count < b.element.count
        }?.element
    }

    static func lastWords(of text: String, count: Int) -> String {
        let words = text.split(separator: " ").map(String.init)
        var tail = words.suffix(count).joined(separator: " ")
        while let last = tail.last, ".!?,".contains(last) { tail.removeLast() }
        return tail
    }

    /// "Joburg taxi ranks, um, without…": the words around a hesitation.
    static func context(of um: HeardWord, in lines: [LineDelivery]) -> String {
        let all = (lines.flatMap(\.words) + lines.flatMap(\.ums)).sorted { $0.start < $1.start }
        guard let i = all.firstIndex(of: um) else { return um.text.lowercased() }
        let before = all[max(0, i - 3)..<i].map(\.text).joined(separator: " ")
        let after = all[(i + 1)..<min(all.count, i + 2)].map(\.text).joined(separator: " ")
        var parts: [String] = []
        if !before.isEmpty { parts.append(before + ",") }
        parts.append(Script.normalize(um.text) + (after.isEmpty ? "" : ","))
        if !after.isEmpty { parts.append(after + "…") }
        let text = parts.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
