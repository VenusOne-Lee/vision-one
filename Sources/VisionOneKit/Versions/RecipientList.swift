import Foundation

/// One person a personalised version is made for.
public struct Recipient: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var company: String
    public var email: String
    /// Captions in this language for their copy, when the take has them.
    public var language: SALanguage?
    /// Anything else from their row, by column name, for `{column}` in
    /// the card line.
    public var extra: [String: String]

    public init(id: Int, name: String, company: String = "", email: String = "",
                language: SALanguage? = nil, extra: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.company = company
        self.email = email
        self.language = language
        self.extra = extra
    }

    /// "Thandi" from "Thandi Mokoena", "Dr Sipho Dlamini" → "Sipho".
    public var firstName: String {
        let titles: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "prof", "adv", "mnr", "mev", "me"]
        let parts = name.split(separator: " ").map(String.init)
        return parts.first { !titles.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            ?? parts.first ?? ""
    }
}

/// A pasted list or a CSV turned into people. Accepts what people copy
/// out of a sheet, an email or a CRM:
///
///     name, company, email          (a header row, any order, any case)
///     Thandi Mokoena, Joburg Taxi Association, thandi@example.co.za
///     Pieter van Wyk <pieter@example.co.za>
///     Sipho Dlamini	Bellville Rank            (tabs from a spreadsheet)
///
/// Blank lines and repeats are skipped; rows it can't read are listed so
/// nothing disappears quietly.
public struct RecipientList: Equatable, Sendable {
    public struct Problem: Equatable, Sendable {
        /// 1-based line in what was pasted.
        public var line: Int
        public var text: String
        public var reason: String
    }

    public static let maxRecipients = 200

    public var recipients: [Recipient]
    public var problems: [Problem]
    /// Rows left out because the same person was already in the list.
    public var repeats: Int
    /// Rows past `maxRecipients`.
    public var overLimit: Int

    public var count: Int { recipients.count }
    public var withCompany: Int { recipients.filter { !$0.company.isEmpty }.count }

    public init(recipients: [Recipient] = [], problems: [Problem] = [], repeats: Int = 0, overLimit: Int = 0) {
        self.recipients = recipients
        self.problems = problems
        self.repeats = repeats
        self.overLimit = overLimit
    }

    enum Column: Equatable {
        case name, first, last, company, email, language, other(String)

        init(header: String) {
            let h = header.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
            switch h {
            case "name", "full name", "fullname", "contact", "contact name", "person", "naam", "igama": self = .name
            case "first name", "firstname", "first", "given name", "voornaam": self = .first
            case "last name", "lastname", "surname", "family name", "van": self = .last
            case "company", "company name", "organisation", "organization", "business", "org", "team", "maatskappy":
                self = .company
            case "email", "email address", "e mail", "mail", "epos": self = .email
            case "language", "lang", "taal", "ulimi": self = .language
            default: self = .other(h)
            }
        }

        var isKnown: Bool {
            if case .other = self { return false }
            return true
        }
    }

    /// Reads pasted text or a CSV file's contents.
    public static func parse(_ text: String) -> RecipientList {
        var rows = CSVRows.parse(text)
        var list = RecipientList()
        guard !rows.isEmpty else { return list }

        // A header row is one where at least one cell names a column we
        // know and no cell looks like an email address or has a digit
        // ("Person 1" is a person, not a header).
        var columns: [Column]?
        let firstCells = rows[0].cells
        let headerGuess = firstCells.map(Column.init(header:))
        if headerGuess.contains(where: { $0.isKnown }), !firstCells.contains(where: Self.looksLikeEmail),
           !firstCells.contains(where: { $0.contains(where: \.isNumber) }) {
            columns = headerGuess
            rows.removeFirst()
        }

        var seen = Set<String>()
        for row in rows {
            let cells = row.cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.contains(where: { !$0.isEmpty }) else { continue }
            let found: Recipient?
            if let columns {
                found = Self.person(cells, columns: columns)
            } else {
                found = Self.person(guessing: cells)
            }
            guard var person = found else {
                list.problems.append(Problem(line: row.line, text: cells.joined(separator: ", "),
                                             reason: "No name in this row"))
                continue
            }
            let key = person.email.isEmpty ? "\(person.name.lowercased())|\(person.company.lowercased())"
                : person.email.lowercased()
            guard seen.insert(key).inserted else {
                list.repeats += 1
                continue
            }
            guard list.recipients.count < maxRecipients else {
                list.overLimit += 1
                continue
            }
            person.id = list.recipients.count
            list.recipients.append(person)
        }
        return list
    }

    static func person(_ cells: [String], columns: [Column]) -> Recipient? {
        var name = "", first = "", last = "", company = "", email = ""
        var language: SALanguage?
        var extra: [String: String] = [:]
        for (i, cell) in cells.enumerated() where !cell.isEmpty {
            let column = i < columns.count ? columns[i] : .other("column \(i + 1)")
            switch column {
            case .name: name = cell
            case .first: first = cell
            case .last: last = cell
            case .company: company = cell
            case .email: email = cell
            case .language: language = SALanguage(code: cell)
            case .other(let key): if !key.isEmpty { extra[key] = cell }
            }
        }
        if name.isEmpty { name = [first, last].filter { !$0.isEmpty }.joined(separator: " ") }
        if name.isEmpty, !email.isEmpty { name = nameFromEmail(email) }
        let cleaned = clean(name)
        guard !cleaned.isEmpty else { return nil }
        return Recipient(id: 0, name: cleaned, company: clean(company), email: email, language: language, extra: extra)
    }

    /// No header: the email is whichever cell has an @, "Name <email>"
    /// is split, the first other cell is the name and the next the company.
    static func person(guessing cells: [String]) -> Recipient? {
        var email = ""
        var rest: [String] = []
        for cell in cells where !cell.isEmpty {
            if let (name, address) = splitAngleEmail(cell) {
                email = address
                if !name.isEmpty { rest.append(name) }
            } else if looksLikeEmail(cell), email.isEmpty {
                email = cell
            } else {
                rest.append(cell)
            }
        }
        var language: SALanguage?
        if let last = rest.last, rest.count > 1, let found = SALanguage(code: last) {
            language = found
            rest.removeLast()
        }
        var name = rest.first.map(clean) ?? ""
        if name.isEmpty, !email.isEmpty { name = nameFromEmail(email) }
        guard !name.isEmpty else { return nil }
        let company = rest.count > 1 ? clean(rest[1]) : ""
        return Recipient(id: 0, name: name, company: company, email: email, language: language)
    }

    static func looksLikeEmail(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@"), !t.contains(" ") else { return false }
        return t[t.index(after: at)...].contains(".")
    }

    /// "Pieter van Wyk <pieter@example.co.za>" → ("Pieter van Wyk", "pieter@example.co.za").
    static func splitAngleEmail(_ text: String) -> (String, String)? {
        guard let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else { return nil }
        let address = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        guard looksLikeEmail(address) else { return nil }
        let name = clean(String(text[..<open]))
        return (name, address)
    }

    /// "thandi.mokoena@example.co.za" → "Thandi Mokoena".
    static func nameFromEmail(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return local.split(whereSeparator: { ".-_+".contains($0) })
            .filter { !$0.allSatisfy(\.isNumber) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Trims spaces and wrapping quotes, and collapses runs of spaces.
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = t.first, let l = t.last, t.count >= 2, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

/// Rows of a CSV, TSV or semicolon file, with quoted cells. The
/// separator is whichever of tab, semicolon and comma the first line uses
/// most, so a South African Excel export (semicolons) works too.
enum CSVRows {
    struct Row: Equatable {
        var line: Int
        var cells: [String]
    }

    static func separator(for text: String) -> Character {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let counts: [(Character, Int)] = ["\t", ";", ","].map { sep in (sep, firstLine.filter { $0 == sep }.count) }
        let best = counts.max { $0.1 < $1.1 }
        return (best?.1 ?? 0) > 0 ? best!.0 : ","
    }

    static func parse(_ text: String) -> [Row] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let sep = separator(for: text)
        var rows: [Row] = []
        var cells: [String] = []
        var cell = ""
        var quoted = false
        var line = 1
        var rowLine = 1
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        cell.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    if c.isNewline { line += 1 }
                    cell.append(c)
                }
            } else if c == "\"", cell.trimmingCharacters(in: .whitespaces).isEmpty {
                cell = ""
                quoted = true
            } else if c == sep {
                cells.append(cell)
                cell = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                cells.append(cell)
                if cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    rows.append(Row(line: rowLine, cells: cells))
                }
                cells = []
                cell = ""
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                line += 1
                rowLine = line
            } else {
                cell.append(c)
            }
            i += 1
        }
        return rows
    }
}
