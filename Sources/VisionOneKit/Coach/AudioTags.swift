import Foundation

/// ElevenLabs audio tags such as [pause], [upbeat] or [slower] that can sit
/// in a script. They direct "Hear it first" and are never shown on the
/// prompter or counted as words.
public enum AudioTags {
    /// Tags the coach offers, by what they do. Eleven v4 accepts free-form
    /// tags too; these are the ones the script coach adds itself.
    public static let pause = "pause"
    public static let slower = "slower"

    /// The text as it is said, tags taken out.
    public static func strip(_ text: String) -> String {
        Script.withoutAudioTags(text)
    }

    /// Tags in the text, lowercased, without brackets, in order.
    public static func tags(in text: String) -> [String] {
        var tags: [String] = []
        var current: String?
        for ch in text {
            if ch == "[" { current = ""; continue }
            if ch == "]", let tag = current {
                let t = tag.trimmingCharacters(in: .whitespaces).lowercased()
                if !t.isEmpty { tags.append(t) }
                current = nil
                continue
            }
            current?.append(ch)
        }
        return tags
    }

    /// Seconds the reading pauses for the tags in `text`: [pause] is a
    /// beat (0.6 s), [long pause] about a second.
    public static func pauseSeconds(in text: String) -> Double {
        tags(in: text).reduce(0) { total, tag in
            if tag.contains("long pause") { return total + 1.0 }
            if tag.contains("pause") || tag == "beat" { return total + 0.6 }
            return total
        }
    }
}
