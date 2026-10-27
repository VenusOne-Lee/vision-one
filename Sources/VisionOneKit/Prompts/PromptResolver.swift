import Foundation

/// Values that fill `{product} {audience} {site} {cta} {ring}` in prompts,
/// usually from the builder's Version One listing.
public struct PromptVariables: Equatable, Sendable {
    public var values: [String: String]

    public init(product: String? = nil, audience: String? = nil, site: String? = nil,
                cta: String? = nil, ring: String? = nil, extra: [String: String] = [:]) {
        var values = extra
        values["product"] = product
        values["audience"] = audience
        values["site"] = site
        values["cta"] = cta
        values["ring"] = ring
        self.values = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public static let known = ["product", "audience", "site", "cta", "ring"]

    /// Replaces `{name}` with its value. Unknown or empty names stay as
    /// written, so a missing listing field is visible rather than silently
    /// blank.
    public func fill(_ text: String) -> String {
        var out = ""
        var rest = text[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(where: { $0 == "}" || $0 == "{" || $0 == "\n" }),
                  rest[close] == "}" else {
                out += "{"
                rest = rest[afterOpen...]
                continue
            }
            let name = String(rest[afterOpen..<close])
            out += values[name.lowercased()] ?? "{\(name)}"
            rest = rest[rest.index(after: close)...]
        }
        return out + String(rest)
    }

    /// Variable names used in `text` that have no value yet.
    public func missing(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\\{([A-Za-z_]+)\\}")
        let range = NSRange(text.startIndex..., in: text)
        var seen: [String] = []
        for match in pattern.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if values[name.lowercased()] == nil, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }
}

/// Where the winning prompt for a part came from.
public enum PromptSource: Equatable, Sendable {
    case moment
    case preset(name: String)
    case template
    case none
}

/// The finished prompt for one part, ready for an agent. `system` carries
/// the house style; `instruction` carries the part's own prompt. `text`
/// joins them for models that take a single prompt.
public struct ResolvedPrompt: Equatable, Sendable {
    public var slot: PromptSlot
    public var system: String?
    public var instruction: String?
    public var source: PromptSource
    /// Variables still unfilled in the result.
    public var missingVariables: [String]

    public var text: String {
        [system, instruction].compactMap { $0 }.joined(separator: "\n\n")
    }

    public var isEmpty: Bool { system == nil && instruction == nil }
}

/// Puts a part's prompt together. The most specific wins:
/// 1. what you asked for this moment (ask bar, a word, a frame),
/// 2. your preset's prompt for the part,
/// 3. the template's default from its prompts.md.
/// The preset's house style (or the template's, when the preset has none)
/// wraps whichever won. Variables are filled last.
public enum PromptResolver {
    public static func resolve(
        slot: PromptSlot,
        template: PromptDocument? = nil,
        preset: PromptPreset? = nil,
        moment: String? = nil,
        variables: PromptVariables = PromptVariables()
    ) -> ResolvedPrompt {
        func clean(_ text: String?) -> String? {
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }

        let house = clean(preset?[.houseStyle]) ?? clean(template?.text(for: .houseStyle))

        var instruction: String?
        var source: PromptSource = .none
        if slot != .houseStyle {
            if let m = clean(moment) {
                instruction = m; source = .moment
            } else if let p = clean(preset?[slot]), let preset {
                instruction = p; source = .preset(name: preset.name)
            } else if let t = clean(template?.text(for: slot)) {
                instruction = t; source = .template
            }
        } else if let m = clean(moment) {
            // Asking about house style itself: the moment adds to it.
            instruction = m; source = .moment
        }

        let system = house.map(variables.fill)
        let filled = instruction.map(variables.fill)
        let missing = variables.missing(in: [system, filled].compactMap { $0 }.joined(separator: "\n"))
        return ResolvedPrompt(slot: slot, system: system, instruction: filled, source: source, missingVariables: missing)
    }

    /// Every part at once, for showing a preset's effect on a template.
    public static func resolveAll(
        template: PromptDocument? = nil,
        preset: PromptPreset? = nil,
        variables: PromptVariables = PromptVariables()
    ) -> [ResolvedPrompt] {
        PromptSlot.allCases.filter { $0 != .houseStyle }.map {
            resolve(slot: $0, template: template, preset: preset, variables: variables)
        }
    }
}
