import Foundation

/// How the script should sound. Picked in the coach; it sets the opening
/// audio tag for "Hear it first" and the tone of the coach's rewrites.
public enum DeliveryTone: String, Codable, CaseIterable, Sendable, Identifiable {
    case calm, lively, punchy

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    /// The Eleven v4 audio tag that sets the reading's mood.
    public var tag: String {
        switch self {
        case .calm: return "calm"
        case .lively: return "upbeat"
        case .punchy: return "excited"
        }
    }

    /// Apple voices have no tags; a rate nudge stands in (0.5 is normal).
    public var appleRate: Float {
        switch self {
        case .calm: return 0.46
        case .lively: return 0.5
        case .punchy: return 0.54
        }
    }
}

/// Turns a script into what "Hear it first" sends to Eleven v4: the tone
/// tag first, a [pause] between paragraphs, and [slower] ahead of lines
/// the coach flagged as long, so you hear where to breathe. Tags the user
/// wrote stay as they are.
public enum DeliveryMarkup {
    public static func reading(_ script: Script, tone: DeliveryTone, flags: [ScriptFlag] = []) -> String {
        let slow = Set(flags.filter { $0.kind == .longSentence }.map(\.line))
        let paragraphs = script.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        var lineIndex = 0
        for paragraph in paragraphs {
            let lines = Script.split(paragraph)
            defer { lineIndex += lines.count }
            // The user's own tags win: their paragraph goes as written.
            if !AudioTags.tags(in: paragraph).isEmpty || lines.isEmpty {
                out.append(paragraph)
                continue
            }
            out.append(lines.enumerated().map { offset, line in
                slow.contains(lineIndex + offset) ? "[\(AudioTags.slower)] " + line.text : line.text
            }.joined(separator: " "))
        }
        let body = out.joined(separator: " [\(AudioTags.pause)] ")
        let opening = AudioTags.tags(in: paragraphs.first ?? "").isEmpty ? "[\(tone.tag)] " : ""
        return opening + body
    }

    /// What an Apple voice reads: the same script with every tag taken out.
    public static func plain(_ script: Script) -> String {
        script.lines.map(\.text).joined(separator: " ")
    }
}
