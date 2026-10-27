import Foundation

/// Finds the words the Keyword and Bold pop styles colour: numbers
/// (R50, 2, 10x, 3.5) and names (the product, or any capitalised word
/// that doesn't start a sentence).
public enum CaptionKeywords {
    public static func isKeyword(_ text: String, startsSentence: Bool, names: Set<String> = []) -> Bool {
        let bare = normalised(text)
        guard !bare.isEmpty else { return false }
        if bare.contains(where: \.isNumber) { return true }
        if names.contains(bare) { return true }
        if startsSentence { return false }
        if commonCapitalised.contains(bare) { return false }
        let letters = text.trimmingCharacters(in: .punctuationCharacters)
        return letters.first?.isUppercase == true
    }

    /// Lowercased, without surrounding punctuation: "Vision," -> "vision".
    public static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
            .lowercased()
    }

    /// Capitalised in the middle of a sentence but not worth a colour.
    static let commonCapitalised: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "ok", "okay",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
}
