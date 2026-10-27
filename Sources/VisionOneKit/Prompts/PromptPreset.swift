import Foundation

/// A named set of prompts you reuse across videos: a house style plus your
/// own version of any template part. Parts a preset leaves out fall back
/// to the template's defaults. Saved as one Markdown file (see
/// `PromptDocument`) so it can be read, diffed and shared.
public struct PromptPreset: Equatable, Sendable, Identifiable {
    public var name: String
    /// Starting point for the Energy dial (Calm, Lively, Viral), as the
    /// dial's own raw value. Nil leaves the template's choice alone.
    public var energy: String?
    public var prompts: [PromptSlot: String]
    /// True for the presets Vision One ships with. Editing one saves a copy.
    public var isBuiltIn: Bool
    /// Sections this version doesn't know, kept so saving loses nothing.
    public var unknownSections: [PromptDocument.Section]

    public var id: String { name }

    public init(name: String, energy: String? = nil, prompts: [PromptSlot: String] = [:],
                isBuiltIn: Bool = false, unknownSections: [PromptDocument.Section] = []) {
        self.name = name
        self.energy = energy
        self.prompts = prompts
        self.isBuiltIn = isBuiltIn
        self.unknownSections = unknownSections
    }

    public subscript(slot: PromptSlot) -> String? {
        get { prompts[slot] }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            prompts[slot] = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// Parts this preset sets, in template order.
    public var changedSlots: [PromptSlot] {
        PromptSlot.allCases.filter { prompts[$0] != nil }
    }

    // MARK: Markdown

    /// Reads a preset file. The name comes from the front matter, or from
    /// `fallbackName` (usually the file name) when it has none.
    public init(markdown: String, fallbackName: String = "Untitled preset") {
        let doc = PromptDocument(markdown: markdown)
        var prompts: [PromptSlot: String] = [:]
        var unknown: [PromptDocument.Section] = []
        for section in doc.sections {
            if let slot = section.slot {
                if !section.text.isEmpty { prompts[slot] = section.text }
            } else {
                unknown.append(section)
            }
        }
        let name = doc.value(for: "name").flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let energy = doc.value(for: "energy").flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.init(name: name, energy: energy, prompts: prompts, unknownSections: unknown)
    }

    public var document: PromptDocument {
        var front: [(key: String, value: String)] = [("name", name)]
        if let energy { front.append(("energy", energy)) }
        let known = PromptSlot.allCases.compactMap { slot in
            prompts[slot].map { PromptDocument.Section(heading: slot.heading, text: $0) }
        }
        return PromptDocument(frontMatter: front, sections: known + unknownSections)
    }

    public var markdown: String { document.markdown }

    /// A file name for the preset: its name with characters Finder or
    /// other systems dislike swapped out.
    public var fileName: String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { banned.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? "Preset" : cleaned) + ".md"
    }
}

// MARK: - Built in

extension PromptPreset {
    /// Three starting points. They only set a house style and a hook, so
    /// each template's own prompts still shape the rest.
    public static let builtIn: [PromptPreset] = [
        PromptPreset(
            name: "Straight talk",
            energy: "calm",
            prompts: [
                .houseStyle: "Clear and direct. Short sentences, no hype words, no filler. Show {product} doing the job rather than describing it.",
                .hook: "Start with the one result {audience} cares about, in a single sentence.",
            ],
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Mzansi warm",
            energy: "lively",
            prompts: [
                .houseStyle: "Talk like a South African builder explaining to a friend. Plain words, short sentences, rand not dollars. Name {product} early and end on {cta}.",
                .hook: "Open on the problem {audience} feels, in under 3 seconds. No \"hey guys\".",
                .captions: "Highlight rand amounts and product names in {ring}.",
            ],
            isBuiltIn: true
        ),
        PromptPreset(
            name: "Launch hype",
            energy: "viral",
            prompts: [
                .houseStyle: "Energetic launch day voice. Fast pace, big promise, proof straight after. Always point to {site}.",
                .hook: "Lead with the boldest true claim about {product} in under 2 seconds.",
                .titleAndPost: "Write a launch post that says what {product} is, who it's for ({audience}), and ends with {cta} and {site}.",
            ],
            isBuiltIn: true
        ),
    ]
}
