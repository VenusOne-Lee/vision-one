import Foundation

/// South African words and place names, so captions spell them the way
/// Mzansi does. Used three ways: as a vocabulary hint for the
/// transcriber, to fix common mis-hearings in captions, and to keep these
/// words from ever being flagged as typos.
public enum MzansiLexicon {
    /// Words and names spelled the local way.
    public static let words: [String] = [
        "Mzansi", "lekker", "eish", "ja", "braai", "bakkie", "robot", "howzit", "sharp", "yebo",
        "aweh", "shame", "now-now", "just now", "boet", "bru", "china", "kasi", "spaza", "tjo",
        "Joburg", "Jozi", "Gqeberha", "eThekwini", "Durban", "Tshwane", "Soweto", "Khayelitsha",
        "KwaZulu-Natal", "Mpumalanga", "Limpopo", "isiZulu", "isiXhosa", "Sesotho", "Setswana",
        "Afrikaans", "Rand", "load shedding", "Eskom", "Version One", "Vision One",
    ]

    /// Lowercased mis-hearing or wrong casing -> local spelling. Kept to
    /// spellings that are wrong in any South African recording.
    static let fixes: [String: String] = [
        "mzanzi": "Mzansi", "mzansi": "Mzansi", "mansi": "Mzansi",
        "lacker": "lekker", "lekka": "lekker", "lecker": "lekker",
        "eesh": "eish", "aish": "eish",
        "brai": "braai", "brye": "braai",
        "backie": "bakkie", "bakky": "bakkie",
        "jozi": "Jozi", "joburg": "Joburg", "jo'burg": "Joburg",
        "gqeberha": "Gqeberha", "ethekwini": "eThekwini", "tshwane": "Tshwane",
        "isizulu": "isiZulu", "isixhosa": "isiXhosa", "kwazulu-natal": "KwaZulu-Natal",
        "eskom": "Eskom",
    ]

    /// A comma-separated hint for the speech model's prompt.
    public static var vocabularyPrompt: String { words.joined(separator: ", ") }

    /// Fixes one word, keeping its punctuation: "lacker!" -> "lekker!".
    /// A fix to a lowercase word keeps a capital at the start of a
    /// sentence: "Lacker" -> "Lekker".
    public static func fix(_ word: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-'"))
        let core = word.trimmingCharacters(in: punctuation)
        guard !core.isEmpty, let fixed = fixes[core.lowercased()], fixed != core else { return word }
        var replacement = fixed
        if core.first?.isUppercase == true, let first = fixed.first, first.isLowercase {
            replacement = first.uppercased() + fixed.dropFirst()
        }
        guard let range = word.range(of: core) else { return word }
        return word.replacingCharacters(in: range, with: replacement)
    }
}
