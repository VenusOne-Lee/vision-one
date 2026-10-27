import Foundation

/// "Ask the video": finds the transcript lines that answer a viewer's
/// question, so the page can quote them with a time to jump to. It runs
/// in the viewer's browser (share-page.html has the same steps in
/// JavaScript), costs nothing and can't make anything up: no line, no
/// answer. This copy lets the app and the MCP server answer the same way
/// and keeps the two honest through tests.
public enum VideoAnswerer {
    /// Small words that say nothing about the topic.
    static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "it", "its", "to", "of", "in", "on", "for",
        "and", "or", "do", "does", "did", "how", "what", "when", "where", "who", "why", "which",
        "can", "could", "i", "you", "your", "my", "me", "this", "that", "be", "with", "at", "by",
        "from", "much", "many", "there", "about", "will", "would", "should", "have", "has",
        "tell", "please", "say", "said", "video",
    ]

    /// Question words mapped to words a speaker would use instead.
    static let related: [String: [String]] = [
        "cost": ["cost", "price", "rand", "free", "pay", "fee"],
        "price": ["price", "cost", "rand", "free", "fee"],
        "pay": ["pay", "paid", "price", "rand"],
        "paid": ["paid", "pay"],
        "expensive": ["price", "cost", "rand", "free"],
        "cheap": ["price", "cost", "rand", "free"],
        "where": ["live", "available", "in"],
        "available": ["available", "live"],
        "when": ["when", "today", "now", "next", "soon"],
        "start": ["start", "open", "sign", "download", "try"],
        "download": ["download", "install", "free"],
        "help": ["help", "support", "contact"],
    ]

    /// The best lines for `question`, best first, at most `limit`. Empty
    /// when nothing in the video matches.
    public static func answer(_ question: String, in lines: [SharePageDocument.Line],
                              limit: Int = 2) -> [SharePageDocument.Line] {
        let terms = Self.terms(for: question)
        guard !terms.isEmpty else { return [] }
        let lineWords = lines.map { Set(words(in: $0.text).map(stem)) }
        // Rarer words count for more, so "price" beats "the app".
        let weight: [String: Double] = Dictionary(uniqueKeysWithValues: terms.map { term -> (String, Double) in
            let found = lineWords.filter { $0.contains(term) }.count
            return (term, found == 0 ? 0 : log(Double(lines.count + 1) / Double(found)) + 1)
        })
        let scored = lines.indices.compactMap { i -> (index: Int, score: Double)? in
            let score = terms.reduce(0.0) { $0 + (lineWords[i].contains($1) ? weight[$1] ?? 0 : 0) }
            return score > 0 ? (i, score) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit)
            .map { lines[$0.index] }
    }

    /// What to look for: the question's own words and the words related
    /// to them, stemmed.
    static func terms(for question: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words(in: question) where !stopWords.contains(word) {
            for term in (related[word] ?? [word]).map(stem) where seen.insert(term).inserted {
                out.append(term)
            }
        }
        return out
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Plural and -ing endings off, so "drivers" finds "driver".
    static func stem(_ word: String) -> String {
        if word.count > 5, word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
