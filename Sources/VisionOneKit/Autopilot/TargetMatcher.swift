import Foundation

/// Finds a step's target among what's on screen, the way a person would:
/// by identifier when the app sets one, then by role and visible name.
/// When nothing fits, `suggestion` offers the likeliest replacement (a
/// renamed button in the same spot) as a dashed fix for the person to keep.
public enum TargetMatcher {
    /// The candidate `target` means, or nil.
    public static func find(_ target: UITarget, in candidates: [UICandidate]) -> UICandidate? {
        if let id = target.identifier, !id.isEmpty {
            let byID = candidates.filter { $0.identifier == id }
            if !byID.isEmpty { return pick(byID, index: target.index) }
            // An identifier that's gone falls through to the name.
        }
        guard let name = target.name.map(normalize), !name.isEmpty else { return nil }
        let sameRole: (UICandidate) -> Bool = { c in
            guard let role = target.role else { return true }
            return c.role == role || Self.family(c.role) == Self.family(role)
        }
        let exact = candidates.filter { sameRole($0) && normalize($0.name) == name }
        if !exact.isEmpty { return pick(exact, index: target.index) }
        // "Pay now" also matches "Pay now →" or "Pay now (R25)".
        let starts = candidates.filter { sameRole($0) && normalize($0.name).hasPrefix(name) }
        if !starts.isEmpty { return pick(starts, index: target.index) }
        // Same name, different kind: a button that became a link.
        let anyRole = candidates.filter { normalize($0.name) == name }
        if anyRole.count == 1 { return anyRole[0] }
        return nil
    }

    /// The likeliest stand-in when `target` can't be found: something of
    /// the same kind near where it was last seen, or with a close name.
    /// Never certain, so it's only ever offered as a proposal.
    public static func suggestion(for target: UITarget, in candidates: [UICandidate],
                                  window: CaptureRect) -> UITarget? {
        let pool = candidates.filter { c in
            c.isEnabled && !c.isSecure && !c.name.isEmpty
                && (target.role == nil || family(c.role) == family(target.role!))
        }
        guard !pool.isEmpty else { return nil }
        var best: (UICandidate, Double)?
        for c in pool {
            var score = 0.0
            if let name = target.name {
                score += similarity(normalize(name), normalize(c.name)) * 2
            }
            if let seen = target.lastSeen {
                let p = c.unitPoint(in: window)
                let distance = ((p.x - seen.x) * (p.x - seen.x) + (p.y - seen.y) * (p.y - seen.y)).squareRoot()
                score += max(0, 1 - distance * 5)
            }
            if score > (best?.1 ?? 0) { best = (c, score) }
        }
        // Too weak a guess is worse than asking.
        guard let best, best.1 >= 0.6 else { return nil }
        let c = best.0
        return UITarget(role: c.role, name: c.name, identifier: c.identifier, lastSeen: c.unitPoint(in: window))
    }

    /// A target for something the person clicked while recording steps:
    /// its identifier and name when it has them, and which one it is when
    /// several share that name.
    public static func target(for element: UICandidate, among candidates: [UICandidate],
                              window: CaptureRect) -> UITarget {
        var target = UITarget(role: element.role, name: element.name.isEmpty ? nil : element.name,
                              identifier: element.identifier, lastSeen: element.unitPoint(in: window))
        if target.identifier == nil, target.name != nil {
            let twins = candidates.filter { $0.role == element.role && normalize($0.name) == normalize(element.name) }
            if twins.count > 1, let i = twins.firstIndex(of: element) { target.index = i }
        }
        return target
    }

    // MARK: Pieces

    /// Several matches: the one asked for, else the first in reading
    /// order (top to bottom, left to right).
    private static func pick(_ list: [UICandidate], index: Int?) -> UICandidate {
        let ordered = list.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        if let index, ordered.indices.contains(index) { return ordered[index] }
        return ordered[0]
    }

    /// Lower case, straight quotes, single spaces, no trailing punctuation.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "…", with: "...")
        let words = folded.split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".:…→ "))
    }

    /// Roles that act alike, so a button that became a pop-up button still
    /// matches.
    static func family(_ role: String) -> String {
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXTabButton": return "press"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField": return "field"
        default: return role
        }
    }

    /// 0...1: shared words over all words.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wa = Set(a.split(separator: " ")), wb = Set(b.split(separator: " "))
        guard !wa.isEmpty || !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }
}
