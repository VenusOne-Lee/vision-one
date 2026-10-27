import Foundation

/// A line on the personalised title card with `{first name}`, `{name}`,
/// `{company}`, `{email}`, `{product}` or any column from the list, and
/// an optional fallback after a bar: `Made for {first name|you}`.
/// A field that is empty and has no fallback drops out with the words
/// that only make sense next to it ("at {company}" goes when there's no
/// company), so a row with gaps still reads well.
public struct CardLine: Codable, Equatable, Sendable {
    public var template: String

    public init(_ template: String) {
        self.template = template
    }

    public static let headline = CardLine("Made for {first name|you}")
    public static let subline = CardLine("{company}")

    /// The fields this line uses, lowercased, without fallbacks.
    public var fields: [String] {
        Self.tokens(in: template).compactMap { token in
            if case let .field(name, _) = token { return name }
            return nil
        }
    }

    enum Token: Equatable {
        case text(String)
        case field(name: String, fallback: String?)
    }

    static func tokens(in template: String) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                if !text.isEmpty { tokens.append(.text(text)); text = "" }
                let inside = template[template.index(after: i)..<close]
                let parts = inside.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let fallback = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
                tokens.append(.field(name: name, fallback: fallback))
                i = template.index(after: close)
            } else {
                text.append(template[i])
                i = template.index(after: i)
            }
        }
        if !text.isEmpty { tokens.append(.text(text)) }
        return tokens
    }

    /// Words that lean on the field after them ("at {company}", "for
    /// {first name}"), dropped with it when it's empty.
    static let leaners: Set<String> = ["at", "for", "from", "of", "with", "by", "to", "vir", "van", "kwa", "ka", "-", "·", "|", "–", "—", "@"]

    /// The line filled in for one person. `product` is the brand name.
    public func filled(for person: Recipient, product: String = "") -> String {
        var out = ""
        for token in Self.tokens(in: template) {
            switch token {
            case let .text(text):
                out += text
            case let .field(name, fallback):
                let value = Self.value(name, for: person, product: product)
                if !value.isEmpty {
                    out += value
                } else if let fallback, !fallback.isEmpty {
                    out += fallback
                } else {
                    // Drop the word leaning on this field, if any.
                    let trimmed = out.trimmingCharacters(in: .whitespaces)
                    if let last = trimmed.split(separator: " ").last, Self.leaners.contains(last.lowercased()) {
                        out = String(trimmed.dropLast(last.count))
                    }
                }
            }
        }
        return Self.tidy(out)
    }

    static func value(_ name: String, for person: Recipient, product: String) -> String {
        switch name {
        case "first name", "first", "firstname", "name.first": return person.firstName
        case "name", "full name": return person.name
        case "company", "organisation", "organization": return person.company
        case "email": return person.email
        case "product", "brand": return product
        case "language": return person.language?.name ?? ""
        default: return person.extra[name] ?? ""
        }
    }

    /// Collapses spaces, and trims separators left at either end or
    /// doubled up by an empty field.
    static func tidy(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let separators: Set<String> = ["-", "·", "|", "–", "—", ",", "&", "+"]
        while let first = words.first, separators.contains(first) { words.removeFirst() }
        while let last = words.last, separators.contains(last) { words.removeLast() }
        var result: [String] = []
        for word in words where !(separators.contains(word) && separators.contains(result.last ?? "")) {
            result.append(word)
        }
        var joined = result.joined(separator: " ")
        while joined.hasSuffix(",") { joined.removeLast() }
        joined = joined.replacingOccurrences(of: " ,", with: ",")
        return joined.trimmingCharacters(in: .whitespaces)
    }
}

/// What to make: the take, who for, and the card's two lines. Saved as
/// versions.json in the take folder so the window reopens as it was.
public struct VersionSettings: Codable, Equatable, Sendable {
    public var headline: CardLine
    public var subline: CardLine
    /// Show the personalised card at the start. Off still names each
    /// file after the person, which some people want for tracking.
    public var titleCard: Bool
    /// Seconds the card stays on screen.
    public var cardDuration: Double
    /// Use each person's language for captions when the take has it.
    public var captionsInTheirLanguage: Bool

    public static let durationRange: ClosedRange<Double> = 1.5...6

    public init(headline: CardLine = .headline, subline: CardLine = .subline, titleCard: Bool = true,
                cardDuration: Double = 2.5, captionsInTheirLanguage: Bool = true) {
        self.headline = headline
        self.subline = subline
        self.titleCard = titleCard
        self.cardDuration = cardDuration
        self.captionsInTheirLanguage = captionsInTheirLanguage
    }

    public var clampedDuration: Double {
        min(max(cardDuration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
    }
}

/// One person's copy: what the card says, where the file goes, and which
/// caption language it uses.
public struct PlannedVersion: Equatable, Identifiable, Sendable {
    public var recipient: Recipient
    public var headline: String
    public var subline: String
    public var fileName: String
    /// Nil keeps the take's own caption language.
    public var captionLanguage: SALanguage?

    public var id: Int { recipient.id }
}

public enum VersionPlanner {
    /// Copies go in "<take>/Versions/".
    public static func folder(for take: Take) -> URL {
        take.folder.appendingPathComponent("Versions", isDirectory: true)
    }

    /// The plan for every person, with file names that never collide.
    /// `available` is the take's translated caption languages.
    public static func plan(_ list: RecipientList, settings: VersionSettings, product: String = "",
                            available: [SALanguage] = []) -> [PlannedVersion] {
        var used = Set<String>()
        return list.recipients.map { person in
            var base = fileStem(for: person)
            if used.contains(base.lowercased()) {
                var n = 2
                while used.contains("\(base) \(n)".lowercased()) { n += 1 }
                base = "\(base) \(n)"
            }
            used.insert(base.lowercased())
            var language: SALanguage?
            if settings.captionsInTheirLanguage, let wanted = person.language, available.contains(wanted) {
                language = wanted
            }
            return PlannedVersion(recipient: person,
                                  headline: settings.headline.filled(for: person, product: product),
                                  subline: settings.subline.filled(for: person, product: product),
                                  fileName: base + ".mp4", captionLanguage: language)
        }
    }

    /// "Thandi Mokoena - Joburg Taxi Association", safe for Finder.
    public static func fileStem(for person: Recipient) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        func safe(_ text: String) -> String {
            text.components(separatedBy: unsafe).joined()
                .split(separator: " ").joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        let name = String(safe(person.name).prefix(60))
        let company = String(safe(person.company).prefix(50))
        let stem = company.isEmpty ? name : "\(name) - \(company)"
        return stem.isEmpty ? "Version \(person.id + 1)" : stem
    }

    /// versions.csv for a mail merge: name, first name, company, email,
    /// file, plus a status column ("made" or why not).
    public static func csv(_ versions: [PlannedVersion], folder: URL, status: [Int: String] = [:]) -> String {
        var rows = [["name", "first name", "company", "email", "language", "file", "status"]]
        for v in versions {
            rows.append([v.recipient.name, v.recipient.firstName, v.recipient.company, v.recipient.email,
                         v.captionLanguage?.name ?? "", folder.appendingPathComponent(v.fileName).path,
                         status[v.id] ?? ""])
        }
        return rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func csvCell(_ text: String) -> String {
        // A leading = + - @ would run as a formula in Excel or Sheets.
        var t = text
        if let first = t.first, "=+-@".contains(first) { t = "'" + t }
        guard t.contains(where: { ",\"\n\r".contains($0) }) else { return t }
        return "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Rough time to make them all: one export per person, at about
    /// `speed` times real time, plus the card.
    public static func estimatedSeconds(count: Int, videoSeconds: Double, cardSeconds: Double, speed: Double = 2.5) -> Double {
        Double(count) * (videoSeconds + cardSeconds) / max(speed, 0.1)
    }
}

extension Take {
    /// versions.json: the card lines last used for this take.
    public var versionSettingsURL: URL { folder.appendingPathComponent("versions.json") }

    public func loadVersionSettings() -> VersionSettings {
        guard let data = try? Data(contentsOf: versionSettingsURL),
              let settings = try? JSONDecoder().decode(VersionSettings.self, from: data) else { return VersionSettings() }
        return settings
    }

    public func saveVersionSettings(_ settings: VersionSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: versionSettingsURL, options: .atomic)
    }
}

extension AgentReceipt {
    /// "Made 38 versions. 2 didn't make it; see versions.csv."
    public static func versions(made: Int, failed: Int) -> String {
        let main = made == 1 ? "Made 1 version." : "Made \(made) versions."
        guard failed > 0 else { return main + " Nothing left your Mac." }
        return main + " \(failed) didn't make it; versions.csv says why."
    }
}
