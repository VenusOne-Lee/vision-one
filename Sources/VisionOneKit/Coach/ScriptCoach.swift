import Foundation

/// One thing the script coach noticed in a line. Shown dashed, as a
/// proposal, with a one-click fix when there is one.
public struct ScriptFlag: Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Too many words to say in one breath.
        case longSentence
        /// Sounds that trip the tongue ("SnapScan scan", "she sells sea shells").
        case tongueTwister
        /// Acronyms and long words that are hard to say or hear.
        case jargon
        /// Big numbers that read badly aloud ("1,250,000").
        case number
        /// The opening takes too long to get to the point.
        case slowOpening
        /// The script doesn't end on one clear ask.
        case ending
    }

    public var id: String { "\(kind.rawValue)-\(line)-\(phrase ?? "")" }
    public var kind: Kind
    /// Index of the line in `Script.lines`.
    public var line: Int
    /// "Long sentence", "Tongue-twister".
    public var title: String
    /// What to do about it, in a sentence.
    public var detail: String
    /// The words in the line the flag is about, when it's a part of it.
    public var phrase: String?
    /// A shorter or easier way to say it. Replaces `phrase` when set,
    /// otherwise the whole line. Nil when only a model can suggest one.
    public var suggestion: String?

    public init(kind: Kind, line: Int, title: String, detail: String, phrase: String? = nil, suggestion: String? = nil) {
        self.kind = kind
        self.line = line
        self.title = title
        self.detail = detail
        self.phrase = phrase
        self.suggestion = suggestion
    }
}

/// How long the script runs when said aloud.
public struct ScriptLength: Equatable, Sendable {
    public var seconds: Double
    public var wordsPerMinute: Double
    /// The purpose's target, when it has one.
    public var target: ClosedRange<Double>?

    public init(seconds: Double, wordsPerMinute: Double, target: ClosedRange<Double>?) {
        self.seconds = seconds
        self.wordsPerMinute = wordsPerMinute
        self.target = target
    }

    public enum Fit: Equatable, Sendable { case short, fits, long, noTarget }

    public var fit: Fit {
        guard let target else { return .noTarget }
        if seconds < target.lowerBound { return .short }
        if seconds > target.upperBound { return .long }
        return .fits
    }

    /// "0:55".
    public var text: String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The script coach's read of a whole script.
public struct ScriptReport: Equatable, Sendable {
    public var flags: [ScriptFlag]
    public var length: ScriptLength

    public init(flags: [ScriptFlag], length: ScriptLength) {
        self.flags = flags
        self.length = length
    }

    public func flags(for line: Int) -> [ScriptFlag] { flags.filter { $0.line == line } }
}

/// Reads a script like a director before you record: long sentences,
/// tongue-twisters, jargon, big numbers, a slow opening and a missing ask
/// at the end, plus how long it runs at your pace. Plain rules, so it runs
/// on the Mac for free and gives the same answer every time; a model only
/// writes better rewrites (`rewriteRequest`). See docs/COACH.md.
public struct ScriptCoach: Sendable {
    /// More words than this in one line is hard to say in one breath.
    public var longSentenceWords = 22
    /// The opening line should get to the hook in this many words.
    public var openingWords = 14
    /// A beat between lines, added to the length.
    public var pauseBetweenLines = 0.35

    public init() {}

    public func check(_ script: Script, pace: SpeakingPace = SpeakingPace(),
                      target: ClosedRange<Double>? = nil) -> ScriptReport {
        var flags: [ScriptFlag] = []
        let lines = script.lines
        for line in lines {
            flags += longSentence(line)
            flags += tongueTwisters(line)
            flags += jargon(line)
            flags += numbers(line)
        }
        if let first = lines.first, first.words.count > openingWords,
           !flags.contains(where: { $0.line == first.id && $0.kind == .longSentence }) {
            flags.append(ScriptFlag(kind: .slowOpening, line: first.id, title: "Slow opening",
                                    detail: "Get to the point in the first \(openingWords) words. People decide in the first few seconds."))
        }
        if let last = lines.last, lines.count >= 2, !Self.endsOnAsk(last.text) {
            flags.append(ScriptFlag(kind: .ending, line: last.id, title: "Ending",
                                    detail: "End on one ask, like where to try it or what to do next."))
        }
        return ScriptReport(flags: flags, length: length(of: script, pace: pace, target: target))
    }

    public func length(of script: Script, pace: SpeakingPace = SpeakingPace(),
                       target: ClosedRange<Double>? = nil) -> ScriptLength {
        let speaking = script.estimatedSeconds(wordsPerMinute: pace.wordsPerMinute)
        let beats = Double(max(0, script.lines.count - 1)) * pauseBetweenLines
        return ScriptLength(seconds: speaking + beats + AudioTags.pauseSeconds(in: script.text),
                            wordsPerMinute: pace.wordsPerMinute, target: target)
    }

    // MARK: Rules

    func longSentence(_ line: ScriptLine) -> [ScriptFlag] {
        guard line.words.count > longSentenceWords else { return [] }
        let split = Self.splitInTwo(line.text)
        return [ScriptFlag(kind: .longSentence, line: line.id, title: "Long sentence",
                           detail: "\(line.words.count) words in one breath. Say it as two.",
                           suggestion: split)]
    }

    /// Splits at the joining word or comma nearest the middle, preferring
    /// ", and" and ", so": "…, and …" becomes two sentences. Nil when
    /// there's nowhere sensible to split.
    static func splitInTwo(_ text: String) -> String? {
        let tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= 8 else { return nil }
        let joiners: Set<String> = ["and", "but", "so", "because", "then", "while"]
        let dropped: Set<String> = ["and", "but", "so", "then", "while"]
        var best: (index: Int, score: Int)?
        let middle = tokens.count / 2
        for i in 3..<(tokens.count - 3) {
            let word = Script.normalize(tokens[i])
            let afterComma = tokens[i - 1].hasSuffix(",") || tokens[i - 1].hasSuffix(";")
            let isJoiner = joiners.contains(word)
            guard isJoiner || afterComma else { continue }
            let score = abs(i - middle) - (afterComma ? 3 : 0) - (afterComma && isJoiner ? 2 : 0)
            if best == nil || score < best!.score { best = (i, score) }
        }
        guard let best else { return nil }
        var head = Array(tokens[..<best.index])
        while let last = head.last, dropped.contains(Script.normalize(last)) { head.removeLast() }
        var first = head.joined(separator: " ")
        while let last = first.last, ",;".contains(last) { first.removeLast() }
        var rest = Array(tokens[best.index...])
        if dropped.contains(Script.normalize(rest[0])), rest.count > 1 { rest.removeFirst() }
        var second = rest.joined(separator: " ")
        second = second.prefix(1).uppercased() + second.dropFirst()
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return first + ". " + second
    }

    func tongueTwisters(_ line: ScriptLine) -> [ScriptFlag] {
        let tokens = line.text.split(separator: " ").map(String.init)
        var flags: [ScriptFlag] = []
        // A word that repeats the end of the one before it: "SnapScan scan".
        for i in 1..<max(1, tokens.count) {
            let a = Script.normalize(tokens[i - 1]), b = Script.normalize(tokens[i])
            guard a.count > b.count, b.count >= 3, a.hasSuffix(b) else { continue }
            let phrase = tokens[i - 1] + " " + tokens[i]
            flags.append(ScriptFlag(kind: .tongueTwister, line: line.id, title: "Tongue-twister",
                                    detail: "“\(Script.normalize(phrase))” repeats a sound. Say it once.",
                                    phrase: phrase, suggestion: tokens[i - 1]))
        }
        // Three of four words starting with the same hard sound.
        let sounds = tokens.map { Self.sound(of: Script.normalize($0)) }
        var i = 0
        while i + 2 < sounds.count {
            let end = min(i + 4, sounds.count)
            guard let sound = sounds[i], sounds[i..<end].filter({ $0 == sound }).count >= 3 else {
                i += 1
                continue
            }
            let phrase = tokens[i..<end].joined(separator: " ")
            if !flags.contains(where: { flag in flag.phrase.map { phrase.contains($0) || $0.contains(phrase) } ?? false }) {
                flags.append(ScriptFlag(kind: .tongueTwister, line: line.id, title: "Tongue-twister",
                                        detail: "Lots of “\(sound)” sounds close together. Swap one word.",
                                        phrase: phrase))
            }
            i = end
        }
        return flags
    }

    /// Little words nobody trips on.
    static let stopWords: Set<String> = ["the", "this", "that", "these", "those", "they", "them", "then", "there", "their",
                                         "than", "with", "what", "when", "where", "which", "who", "will", "was", "were",
                                         "for", "from", "have", "has", "had", "how", "not", "now", "can", "you", "your",
                                         "she", "his", "her", "him", "see", "say", "but", "just", "like", "make", "more",
                                         "without", "before", "after", "about", "because", "every", "into", "over", "under",
                                         "only", "also", "really", "exactly", "going", "want", "some", "here", "very", "much"]

    /// The hard sound a word starts with, grouped the way tongues trip:
    /// s, sh, ch and z are one hiss; c and k are one click. Nil for words
    /// that start with a vowel or are too short to matter.
    static func sound(of word: String) -> String? {
        guard word.count >= 3, !stopWords.contains(word), let first = word.first, first.isLetter else { return nil }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        if vowels.contains(first) { return nil }
        if word.hasPrefix("th") { return "th" }
        switch first {
        case "s", "z", "x": return "s"
        case "c": return word.hasPrefix("ch") ? "s" : "k"
        case "q": return "k"
        case "p", "b", "t", "d", "k", "f", "g", "w", "r", "l", "m", "n", "v", "j", "h": return String(first)
        default: return nil
        }
    }

    /// Acronyms people say as words or know already.
    static let knownAcronyms: Set<String> = ["AI", "SA", "UI", "API", "MCP", "OK", "TV", "PDF", "URL", "USB", "CEO", "FAQ",
                                             "ID", "IT", "PC", "MP4", "ATM", "JHB", "CPT", "DM", "PM", "AM", "UK", "US", "EU"]

    func jargon(_ line: ScriptLine) -> [ScriptFlag] {
        var flags: [ScriptFlag] = []
        for raw in line.text.split(separator: " ").map(String.init) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !word.isEmpty, !word.contains("."), !word.contains("/") else { continue }
            let letters = word.filter(\.isLetter)
            let isAcronym = letters.count >= 3 && letters == letters.uppercased() && word.allSatisfy { $0.isLetter || $0.isNumber }
            if isAcronym, !Self.knownAcronyms.contains(word) {
                flags.append(ScriptFlag(kind: .jargon, line: line.id, title: "Jargon",
                                        detail: "Will people know “\(word)”? Say what it means, or spell out how to say it.",
                                        phrase: word))
            } else if Self.syllables(word) >= 7 {
                flags.append(ScriptFlag(kind: .jargon, line: line.id, title: "Mouthful",
                                        detail: "“\(word)” is a mouthful. A shorter word is easier to say and hear.",
                                        phrase: word))
            }
        }
        return flags
    }

    /// A rough syllable count from vowel groups, good enough to spot mouthfuls.
    static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter(\.isLetter)
        guard !w.isEmpty else { return 0 }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        var previous = false
        for ch in w {
            let v = vowels.contains(ch)
            if v && !previous { count += 1 }
            previous = v
        }
        if w.hasSuffix("e") && !w.hasSuffix("le") && count > 1 { count -= 1 }
        return max(1, count)
    }

    func numbers(_ line: ScriptLine) -> [ScriptFlag] {
        var flags: [ScriptFlag] = []
        for raw in line.text.split(separator: " ").map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: ",")).union(.whitespaces))
            var prefix = ""
            var digits = trimmed
            if let first = digits.first, first == "R" || first == "$" { prefix = String(first); digits.removeFirst() }
            let plain = digits.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
            guard plain.count >= 5, plain.allSatisfy(\.isNumber), let value = Double(plain) else { continue }
            flags.append(ScriptFlag(kind: .number, line: line.id, title: "Big number",
                                    detail: "Round it so it's easy to say and remember.",
                                    phrase: trimmed, suggestion: Self.spoken(value, prefix: prefix)))
        }
        return flags
    }

    /// 1_250_000 -> "1.25 million"; 48_500 -> "about 48,000"; R in front stays.
    static func spoken(_ value: Double, prefix: String) -> String {
        func trim(_ x: Double) -> String {
            let s = String(format: "%.2f", x)
            var t = s
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }
        if value >= 1_000_000_000 { return prefix + trim(value / 1_000_000_000) + " billion" }
        if value >= 1_000_000 { return prefix + trim(value / 1_000_000) + " million" }
        let rounded = (value / 1000).rounded() * 1000
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let text = formatter.string(from: NSNumber(value: rounded)) ?? String(Int(rounded))
        return (rounded == value ? "" : "about ") + prefix + text
    }

    /// True when the last line asks for something: a verb people act on,
    /// a link, or a question.
    static func endsOnAsk(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http") || lower.contains(".co.za") || lower.contains(".com") || lower.contains(".app")
            || lower.contains(".io") || lower.hasSuffix("?") { return true }
        let asks = ["try", "download", "sign up", "join", "visit", "go to", "get it", "grab", "follow", "subscribe",
                    "book", "start", "check out", "head to", "tell me", "let me know", "reply", "comment", "share", "install", "click"]
        return asks.contains { lower.contains($0) }
    }

    // MARK: Better rewrites

    public static let rewriteTask = AITask("coach.rewrite")

    /// Asks any rung (Apple's on-device model is enough) for an easier way
    /// to say each flagged line. Only the script's words are sent.
    public func rewriteRequest(_ script: Script, flags: [ScriptFlag], tone: DeliveryTone = .lively) -> AIRequest? {
        let ids = Array(Set(flags.map(\.line))).sorted()
        guard !ids.isEmpty else { return nil }
        let lines = script.lines
        let input = ids.compactMap { id in lines.first { $0.id == id } }.map { line in
            let notes = flags.filter { $0.line == line.id }.map(\.title).joined(separator: ", ")
            return "\(line.id): \(line.text)   (\(notes))"
        }.joined(separator: "\n")
        return AIRequest(task: Self.rewriteTask, summary: "Suggest easier ways to say \(ids.count) script lines",
                         instructions: """
                         You coach people who record short product videos. Rewrite each numbered line so it is easy to say \
                         out loud in one breath: short words, under 18 words, no tongue-twisters, same meaning, \(tone.rawValue) tone. \
                         Keep names, links and prices exactly as written. If a line should be two sentences, write both.
                         """,
                         input: input, format: .json(shape: #"[{"line": 2, "say": "See the queue before you leave."}]"#))
    }

    public struct Rewrite: Codable, Equatable, Sendable {
        public var line: Int
        public var say: String
    }

    /// Model rewrites as suggestions on the flags of their line.
    public func applying(_ rewrites: [Rewrite], to report: ScriptReport) -> ScriptReport {
        var report = report
        for rewrite in rewrites where !rewrite.say.trimmingCharacters(in: .whitespaces).isEmpty {
            for i in report.flags.indices where report.flags[i].line == rewrite.line && report.flags[i].phrase == nil {
                report.flags[i].suggestion = rewrite.say
            }
        }
        return report
    }
}

extension Script {
    /// The script with a flag's suggestion put in: the phrase swapped, or
    /// the whole line replaced. Audio tags elsewhere stay where they are.
    public func applying(_ flag: ScriptFlag) -> Script {
        guard let suggestion = flag.suggestion, let line = lines.first(where: { $0.id == flag.line }) else { return self }
        let target = flag.phrase ?? line.text
        // Search from the line's own text so the same phrase in another line isn't touched.
        guard let lineRange = text.range(of: line.text) ?? text.range(of: target) else { return self }
        var newText = text
        if flag.phrase != nil, let phraseRange = text.range(of: target, range: lineRange) {
            newText.replaceSubrange(phraseRange, with: suggestion)
        } else {
            newText.replaceSubrange(lineRange, with: suggestion)
        }
        return Script(text: newText)
    }
}
