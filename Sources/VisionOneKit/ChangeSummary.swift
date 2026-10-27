import Foundation

/// One row of the editor's Changes list: every AI suggestion of one kind,
/// such as all the filler cuts. Dashed while any of them is unanswered,
/// solid once accepted, muted when switched off.
public struct ChangeGroup: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case fillers, pauses, retakes, deadAir, trims, zooms, blurs, soundEffects

        /// The cut reason this kind groups, or nil for zooms, blurs and
        /// sound effects, which live in their own files.
        public var cutReason: String? {
            switch self {
            case .fillers: return Cut.Reason.filler
            case .pauses: return Cut.Reason.pause
            case .retakes: return Cut.Reason.`repeat`
            case .deadAir: return Cut.Reason.deadAir
            case .trims: return Cut.Reason.trim
            case .zooms, .blurs, .soundEffects: return nil
            }
        }

        /// For undo menu names: "Accept Fillers".
        public var noun: String {
            switch self {
            case .fillers: return "Fillers"
            case .pauses: return "Pauses"
            case .retakes: return "Retakes"
            case .deadAir: return "Silence"
            case .trims: return "Suggested Cuts"
            case .zooms: return "Zooms"
            case .blurs: return "Blurs"
            case .soundEffects: return "Sound Effects"
            }
        }
    }

    public enum State: Equatable, Sendable {
        /// At least one suggestion is still waiting: dashed.
        case proposed
        /// Every live suggestion is accepted: solid ink.
        case accepted
        /// All of them turned down: muted.
        case off
    }

    public var kind: Kind
    /// Suggestions still in play (proposed or accepted), or all of them
    /// when the row is off, so the title still says what it was.
    public var count: Int
    public var state: State
    public var title: String
    public var detail: String
    /// Seconds the row's cuts take out when on. 0 for effects.
    public var removedSeconds: Double

    public var id: Kind { kind }

    public init(kind: Kind, count: Int, state: State, title: String, detail: String, removedSeconds: Double = 0) {
        self.kind = kind
        self.count = count
        self.state = state
        self.title = title
        self.detail = detail
        self.removedSeconds = removedSeconds
    }
}

/// Builds the Changes list from the take's files. Pure, so it can be
/// tested: the editor passes what it has open.
public enum ChangeSummary {
    /// The rows that exist, in the list's order. Cuts the user made in the
    /// transcript, and zooms, blurs and sounds they added themselves, are
    /// theirs, not suggestions, so they never appear here.
    public static func groups(edits: EditList, words: [TranscriptWord] = [], zooms: ZoomList = ZoomList(),
                              blurs: BlurList = BlurList(), sound: SoundPlan = SoundPlan()) -> [ChangeGroup] {
        var groups: [ChangeGroup] = []
        for kind in ChangeGroup.Kind.allCases {
            if let reason = kind.cutReason {
                let cuts = edits.cuts.filter { $0.reason == reason }
                if let group = cutGroup(kind, cuts: cuts, words: words) { groups.append(group) }
                continue
            }
            switch kind {
            case .zooms:
                let items = zooms.zooms.filter { $0.reason == Zoom.Reason.click }
                guard case let (state, shown)? = summarize(items.map(\.state)) else { continue }
                let times = items.filter { state == .off || $0.state != .rejected }.map(\.start)
                groups.append(ChangeGroup(kind: kind, count: shown, state: state,
                                          title: "\(shown) \(shown == 1 ? "zoom" : "zooms") on clicks",
                                          detail: at(times)))
            case .blurs:
                let items = blurs.blurs.filter { $0.reason == Blur.Reason.secret }
                guard case let (state, shown)? = summarize(items.map(\.state)) else { continue }
                let live = items.filter { state == .off || $0.state != .rejected }
                let kinds = Set(live.compactMap(\.kind))
                let what = kinds.count == 1 ? kinds.first! : (shown == 1 ? "secret" : "secrets")
                groups.append(ChangeGroup(kind: kind, count: shown, state: state,
                                          title: "Blurred \(shown) \(what)",
                                          detail: at(live.map(\.start))))
            case .soundEffects:
                let items = sound.effects.filter { !$0.isManual }
                let states = items.map { Cut.State(rawValue: $0.state.rawValue) ?? .proposed }
                guard case let (state, shown)? = summarize(states) else { continue }
                let live = items.filter { state == .off || $0.state != .rejected }
                var names: [String] = []
                for effect in live where !names.contains(effect.soundID) { names.append(effect.soundID) }
                var detail = names.prefix(3).joined(separator: ", ")
                detail += (detail.isEmpty ? "" : " · ") + "energy \(sound.energy.title)"
                groups.append(ChangeGroup(kind: kind, count: shown, state: state,
                                          title: "\(shown) sound \(shown == 1 ? "effect" : "effects")",
                                          detail: detail))
            default:
                continue
            }
        }
        return groups
    }

    /// The row's state and how many it counts, or nil when there's nothing.
    static func summarize(_ states: [Cut.State]) -> (ChangeGroup.State, Int)? {
        guard !states.isEmpty else { return nil }
        let live = states.filter { $0 != .rejected }
        if live.isEmpty { return (.off, states.count) }
        return (live.contains(.proposed) ? .proposed : .accepted, live.count)
    }

    private static func cutGroup(_ kind: ChangeGroup.Kind, cuts: [Cut], words: [TranscriptWord]) -> ChangeGroup? {
        guard case let (state, shown)? = summarize(cuts.map(\.state)) else { return nil }
        let live = cuts.filter { state == .off || $0.state != .rejected }
        let removed = mergedDuration(live.map(\.span))
        let minus = "−\(seconds(removed)) s"
        let title: String
        var detail: String
        switch kind {
        case .fillers:
            title = "Removed \(shown) \(shown == 1 ? "filler" : "fillers")"
            let found = distinctWords(in: live, words: words).prefix(3).map { "“\($0)”" }
            detail = found.joined(separator: ", ")
        case .pauses:
            title = "Cut \(shown) long \(shown == 1 ? "pause" : "pauses")"
            detail = shortestGap(around: live, words: words).map { "over \(String(format: "%.1f", $0)) s" } ?? ""
        case .retakes:
            title = shown == 1 ? "Kept your last take" : "Kept your last take \(shown) times"
            let first = live.min { $0.start < $1.start }.map { cutWords([$0], words: words) } ?? []
            detail = first.isEmpty ? "" : "“\(first.prefix(3).joined(separator: " "))…” said again"
        case .deadAir:
            title = "Trimmed silence at the start and end"
            detail = ""
        default:
            title = "\(shown) suggested \(shown == 1 ? "cut" : "cuts")"
            detail = "from the Editor"
        }
        detail += (detail.isEmpty ? "" : " · ") + minus
        return ChangeGroup(kind: kind, count: shown, state: state, title: title, detail: detail,
                           removedSeconds: removed)
    }

    /// Total length of `spans` once overlaps are merged.
    static func mergedDuration(_ spans: [TimeSpan]) -> Double {
        var total = 0.0
        var current: TimeSpan?
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if var open = current, span.start <= open.end {
                open.end = max(open.end, span.end)
                current = open
            } else {
                if let open = current { total += open.duration }
                current = span
            }
        }
        if let open = current { total += open.duration }
        return total
    }

    /// "7" or "0.4": whole seconds once there's at least one.
    static func seconds(_ value: Double) -> String {
        value >= 1 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
    }

    /// The words whose middle falls inside one of `cuts`, as spoken.
    private static func cutWords(_ cuts: [Cut], words: [TranscriptWord]) -> [String] {
        words.filter { word in
            let middle = (word.start + word.end) / 2
            return cuts.contains { $0.span.contains(middle) }
        }
        .map(\.text)
    }

    /// The filler words found, lowercased without punctuation, first seen first.
    private static func distinctWords(in cuts: [Cut], words: [TranscriptWord]) -> [String] {
        var seen: [String] = []
        for text in cutWords(cuts, words: words) {
            let plain = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if !plain.isEmpty, !seen.contains(plain) { seen.append(plain) }
        }
        return seen
    }

    /// The shortest silence between words that a pause cut sits in,
    /// rounded down to a tenth, for "over 1.5 s".
    private static func shortestGap(around cuts: [Cut], words: [TranscriptWord]) -> Double? {
        guard words.count > 1 else { return nil }
        var shortest: Double?
        for cut in cuts {
            let middle = (cut.start + cut.end) / 2
            guard let after = words.firstIndex(where: { $0.start >= middle }), after > 0 else { continue }
            let gap = words[after].start - words[after - 1].end
            guard gap > 0 else { continue }
            shortest = min(shortest ?? gap, gap)
        }
        return shortest.map { ($0 * 10).rounded(.down) / 10 }
    }

    /// "at 0:12, 1:05, 1:40" for the first three moments.
    private static func at(_ times: [Double]) -> String {
        let sorted = times.sorted()
        guard !sorted.isEmpty else { return "" }
        var text = "at " + sorted.prefix(3).map { Timecode.short(from: $0) }.joined(separator: ", ")
        if sorted.count > 3 { text += " and \(sorted.count - 3) more" }
        return text
    }
}

// MARK: Switching a row

extension EditList {
    /// Sets every cut of one Changes row to `state`: on accepts them all,
    /// off rejects them all. Does nothing for effect rows.
    public mutating func setState(_ state: Cut.State, forChange kind: ChangeGroup.Kind) {
        guard let reason = kind.cutReason else { return }
        for i in cuts.indices where cuts[i].reason == reason { cuts[i].state = state }
    }

    /// "Undo all": the take as it was recorded. Cuts the user made are
    /// removed; suggestions are rejected, not removed, so auto-clean
    /// doesn't offer them again.
    public mutating func revertAll() {
        cuts.removeAll { $0.state == .accepted && ($0.reason == nil || $0.reason == Cut.Reason.word) }
        for i in cuts.indices where cuts[i].state != .rejected { cuts[i].state = .rejected }
    }
}

extension ZoomList {
    /// The "zooms on clicks" row: every zoom planned from a click.
    public mutating func setState(_ state: ProposalState, forChange kind: ChangeGroup.Kind) {
        guard kind == .zooms else { return }
        for i in zooms.indices where zooms[i].reason == Zoom.Reason.click { zooms[i].state = state }
    }

    /// "Undo all": every zoom off. They stay in the list to turn back on.
    public mutating func rejectAll() {
        for i in zooms.indices { zooms[i].state = .rejected }
    }
}

extension BlurList {
    /// The "blurred secrets" row: every blur the secret scan found.
    public mutating func setState(_ state: ProposalState, forChange kind: ChangeGroup.Kind) {
        guard kind == .blurs else { return }
        for i in blurs.indices where blurs[i].reason == Blur.Reason.secret { blurs[i].state = state }
    }
}

extension SoundPlan {
    /// The "sound effects" row: every effect the Energy dial suggested.
    public mutating func setState(_ state: PlacedEffect.State, forChange kind: ChangeGroup.Kind) {
        guard kind == .soundEffects else { return }
        for i in effects.indices where !effects[i].isManual { effects[i].state = state }
    }

    /// "Undo all": every effect off. The music bed stays.
    public mutating func rejectAllEffects() {
        for i in effects.indices { effects[i].state = .rejected }
    }
}
