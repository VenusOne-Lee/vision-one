import Foundation

/// The parts of a template that each have their own prompt. A template's
/// prompts.md and a preset file both use these as `## Heading` names.
/// House style sits above all the others and wraps whichever prompt wins.
public enum PromptSlot: String, CaseIterable, Codable, Sendable, Identifiable {
    case houseStyle
    case hook
    case title
    case body
    case outro
    case captions
    case zooms
    case bRoll
    case music
    case soundEffects
    case thumbnail
    case titleAndPost
    case chapters
    case clip

    public var id: String { rawValue }

    /// The heading written in Markdown files and shown in the app.
    public var heading: String {
        switch self {
        case .houseStyle: return "House style"
        case .hook: return "Hook"
        case .title: return "Title"
        case .body: return "Body"
        case .outro: return "Outro"
        case .captions: return "Captions"
        case .zooms: return "Zooms"
        case .bRoll: return "B-roll"
        case .music: return "Music"
        case .soundEffects: return "Sound effects"
        case .thumbnail: return "Thumbnail"
        case .titleAndPost: return "Title + post"
        case .chapters: return "Chapters"
        case .clip: return "Clips"
        }
    }

    /// The key the AI agents use for this part in an `AgentBrief`.
    public var agentKey: String {
        switch self {
        case .titleAndPost: return "post"
        default: return rawValue
        }
    }

    /// Reads a heading the way people actually type it: any case, "and"
    /// or "+", with or without hyphens and spaces.
    public init?(heading: String) {
        let key = Self.normalise(heading)
        guard let slot = Self.allCases.first(where: { Self.normalise($0.heading) == key || $0.rawValue.lowercased() == key })
            ?? Self.aliases[key] else { return nil }
        self = slot
    }

    private static let aliases: [String: PromptSlot] = [
        "house": .houseStyle,
        "brand": .houseStyle,
        "style": .houseStyle,
        "sfx": .soundEffects,
        "post": .titleAndPost,
        "titlepost": .titleAndPost,
        "clip": .clip,
        "chapter": .chapters,
    ]

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " and ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0 != "and" }
            .joined()
    }
}
