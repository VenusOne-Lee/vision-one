import Foundation

/// Where the intro, the edited video and the outro sit on the export
/// clock. Export renders the cards for their ranges and the recording for
/// `body`; captions and other overlays use body time (`bodyTime`).
public struct TemplatePlan: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case intro, body, outro
    }

    /// Output seconds.
    public let intro: Range<Double>?
    public let body: Range<Double>
    public let outro: Range<Double>?

    /// Length of the whole export.
    public var duration: Double { outro?.upperBound ?? body.upperBound }

    public init(introDuration: Double?, bodyDuration: Double, outroDuration: Double?) {
        let body = max(0, bodyDuration)
        let intro = introDuration.map { max(0, $0) } ?? 0
        let outro = outroDuration.map { max(0, $0) } ?? 0
        self.intro = intro > 0 ? 0..<intro : nil
        self.body = intro..<(intro + body)
        self.outro = outro > 0 ? (intro + body)..<(intro + body + outro) : nil
    }

    /// What the brand kit and template ask for. No body means no cards:
    /// an empty export stays empty.
    public init(brand: BrandKit, look: TemplateLook? = nil, bodyDuration: Double) {
        func wanted(_ card: BrandCard, _ choice: TemplateLook.Card?) -> Double? {
            guard bodyDuration > 0 else { return nil }
            switch choice ?? .brand {
            case .off: return nil
            case .brand: return card.enabled ? card.clampedDuration : nil
            case .file: return card.clampedDuration
            }
        }
        self.init(introDuration: wanted(brand.intro, look?.intro),
                  bodyDuration: bodyDuration,
                  outroDuration: wanted(brand.outro, look?.outro))
    }

    public var hasCards: Bool { intro != nil || outro != nil }

    public func part(at t: Double) -> Part {
        if let intro, intro.contains(t) { return .intro }
        if let outro, t >= outro.lowerBound { return .outro }
        return .body
    }

    /// Time on the edited video (what captions use) for an output time,
    /// or nil during a card.
    public func bodyTime(forOutput t: Double) -> Double? {
        guard part(at: t) == .body, t >= body.lowerBound else { return nil }
        return min(t - body.lowerBound, body.upperBound - body.lowerBound)
    }

    /// Seconds into a card for an output time.
    public func cardTime(forOutput t: Double) -> Double? {
        switch part(at: t) {
        case .intro: return intro.map { t - $0.lowerBound }
        case .outro: return outro.map { t - $0.lowerBound }
        case .body: return nil
        }
    }
}
