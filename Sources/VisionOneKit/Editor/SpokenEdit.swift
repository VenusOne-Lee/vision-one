import Foundation

/// What you said while holding Space, read on the Mac with no AI: the
/// common asks are done on the spot at the moment you spoke, anything
/// else goes to Ask with that moment attached.
public enum SpokenEdit: Equatable, Sendable {
    /// "cut this bit", "cut that", "lose this sentence": the sentence
    /// playing when you spoke (or the one just before).
    case cutSentence
    /// "cut this word"
    case cutWord
    /// "zoom in here", "zoom in on the queue count"
    case zoomIn
    /// "zoom out", "no zoom here"
    case zoomOut
    /// "blur this": you then circle or scribble what to hide.
    case blur
    /// "music quieter" / "music louder"
    case music(louder: Bool)
    /// "undo", "take that back"
    case undo
    /// Anything else, for Ask.
    case ask(String)

    public static func parse(_ said: String) -> SpokenEdit {
        let text = said.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "'")).inverted)
            .joined(separator: " ")
        let words = text.split(separator: " ").map(String.init)
        func has(_ any: String...) -> Bool { any.contains { words.contains($0) } }
        func phrase(_ any: String...) -> Bool { any.contains { (" " + words.joined(separator: " ") + " ").contains(" \($0) ") } }

        if words.isEmpty { return .ask(said) }
        if phrase("undo", "undo that", "take that back", "put it back") { return .undo }
        if has("zoom", "zooming") {
            if phrase("zoom out", "no zoom", "don't zoom", "stop zooming", "remove the zoom") { return .zoomOut }
            return .zoomIn
        }
        if phrase("closer here", "get closer") { return .zoomIn }
        if has("blur", "hide", "redact") { return .blur }
        if has("music", "song", "track") {
            if has("louder", "up", "higher", "more") { return .music(louder: true) }
            if has("quieter", "softer", "down", "lower", "less") { return .music(louder: false) }
        }
        if has("cut", "remove", "delete", "lose", "drop", "trim") {
            // Only short, pointing asks; "cut the intro to ten seconds"
            // is a job for Ask.
            let pointing = has("this", "that", "here", "it", "bit", "part", "sentence", "line")
            if pointing && words.count <= 6 {
                return has("word") ? .cutWord : .cutSentence
            }
        }
        return .ask(said.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The sentence a spoken "cut this" means: the one playing at `t`,
    /// else the last one that ended within `lookBack` seconds before it.
    public static func sentence(at t: Double, in sentences: [SpokenSentence],
                                lookBack: Double = 3) -> SpokenSentence? {
        if let playing = sentences.first(where: { $0.start <= t && t < $0.end }) { return playing }
        return sentences.last { $0.end <= t && t - $0.end <= lookBack }
    }
}
