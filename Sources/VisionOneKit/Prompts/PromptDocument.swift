import Foundation

/// A Markdown file of prompts: optional `---` front matter of `key: value`
/// lines, then one `## Heading` section per template part.
///
///     ---
///     name: Mzansi warm
///     energy: lively
///     ---
///
///     ## House style
///     Talk like a South African builder explaining to a friend.
///
///     ## Hook
///     Open on the problem {audience} feels, in under 3 seconds.
///
/// Headings that aren't a known part are kept as they are, so a file
/// written by a newer Vision One survives a round trip through an older one.
public struct PromptDocument: Equatable, Sendable {
    public var frontMatter: [(key: String, value: String)]
    public var sections: [Section]

    public struct Section: Equatable, Sendable {
        public var heading: String
        public var text: String

        public init(heading: String, text: String) {
            self.heading = heading
            self.text = text
        }

        public var slot: PromptSlot? { PromptSlot(heading: heading) }
    }

    public init(frontMatter: [(key: String, value: String)] = [], sections: [Section] = []) {
        self.frontMatter = frontMatter
        self.sections = sections
    }

    public static func == (lhs: PromptDocument, rhs: PromptDocument) -> Bool {
        lhs.sections == rhs.sections
            && lhs.frontMatter.map(\.key) == rhs.frontMatter.map(\.key)
            && lhs.frontMatter.map(\.value) == rhs.frontMatter.map(\.value)
    }

    public func value(for key: String) -> String? {
        frontMatter.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    /// The text for a part, or nil when the file doesn't set it (or leaves
    /// it empty, which means "use the default").
    public func text(for slot: PromptSlot) -> String? {
        guard let section = sections.last(where: { $0.slot == slot }), !section.text.isEmpty else { return nil }
        return section.text
    }

    // MARK: Reading

    public init(markdown: String) {
        var lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")[...]
        var frontMatter: [(key: String, value: String)] = []

        // Front matter only counts when the file opens with it.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[lines.index(after: lines.startIndex)..<close] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty { frontMatter.append((key, value)) }
            }
            lines = lines[lines.index(after: close)...]
        }

        var sections: [Section] = []
        var heading: String?
        var body: [String] = []
        var inFence = false

        func flush() {
            if let heading {
                sections.append(Section(heading: heading, text: Self.trimBlankLines(body)))
            }
            body = []
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("## ") {
                flush()
                heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else if heading != nil {
                body.append(line)
            }
        }
        flush()

        self.init(frontMatter: frontMatter, sections: sections)
    }

    private static func trimBlankLines(_ lines: [String]) -> String {
        var slice = lines[...]
        while let first = slice.first, first.trimmingCharacters(in: .whitespaces).isEmpty { slice = slice.dropFirst() }
        while let last = slice.last, last.trimmingCharacters(in: .whitespaces).isEmpty { slice = slice.dropLast() }
        return slice.joined(separator: "\n")
    }

    // MARK: Writing

    public var markdown: String {
        var out: [String] = []
        if !frontMatter.isEmpty {
            out.append("---")
            for (key, value) in frontMatter {
                // Quote values that would otherwise read back differently.
                let needsQuotes = value != value.trimmingCharacters(in: .whitespaces) || value.contains(":")
                out.append("\(key): \(needsQuotes ? "\"\(value)\"" : value)")
            }
            out.append("---")
        }
        for section in sections {
            if !out.isEmpty { out.append("") }
            out.append("## \(section.heading)")
            if !section.text.isEmpty { out.append(section.text) }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
