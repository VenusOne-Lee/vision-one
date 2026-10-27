import Foundation

/// Finds things in on-screen text that shouldn't be in a video: API keys,
/// tokens, passwords after "password=", private keys, card and SA ID
/// numbers. Patterns follow the well-known prefixes gitleaks and
/// trufflehog look for, plus an entropy check for long random strings
/// with no prefix. Works on one line of OCR text at a time.
public enum SecretScanner {
    public struct Match: Equatable, Sendable {
        /// What it looks like, for the changes list ("OpenAI key").
        public let kind: String
        /// The part of the line to hide.
        public let range: Range<String.Index>
    }

    private struct Rule {
        let kind: String
        let regex: NSRegularExpression
        /// Capture group to hide; 0 is the whole match.
        let group: Int
        var check: ((String) -> Bool)?
    }

    private static func rule(_ kind: String, _ pattern: String, group: Int = 0,
                             caseInsensitive: Bool = false, check: ((String) -> Bool)? = nil) -> Rule {
        // The patterns are fixed, so a bad one is a programming error.
        let regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        return Rule(kind: kind, regex: regex, group: group, check: check)
    }

    /// Most specific first: when two rules hit the same text, the first wins.
    private static let rules: [Rule] = [
        rule("Private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        rule("Anthropic key", #"sk-ant-[A-Za-z0-9_\-]{16,}"#),
        rule("OpenAI key", #"sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}"#),
        rule("Stripe key", #"(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}"#),
        rule("GitHub token", #"github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{30,}"#),
        rule("AWS key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        rule("Google key", #"AIza[0-9A-Za-z_\-]{35}"#),
        rule("Slack token", #"xox[abposr]-[0-9A-Za-z\-]{10,}"#),
        rule("Hugging Face token", #"\bhf_[A-Za-z0-9]{30,}"#),
        rule("Token", #"eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
        rule("Password", #"[a-z][a-z0-9+.\-]*://[^:@/\s]+:([^@\s]{3,})@"#, group: 1, caseInsensitive: true),
        rule("Secret",
             #"(?:password|passwd|pwd|secret|token|api[_\-]?key|access[_\-]?key|client[_\-]?secret|auth)["']?\s*[:=]\s*["']?([^\s"',;]{6,})"#,
             group: 1, caseInsensitive: true, check: { !isPlaceholder($0) }),
        rule("SA ID number", #"(?<![0-9])[0-9]{13}(?![0-9])"#, check: isSouthAfricanID),
        rule("Card number", #"(?<![0-9])(?:[0-9][ \-]?){12,18}[0-9](?![0-9])"#, check: isCardNumber),
        rule("Possible key", #"(?<![A-Za-z0-9_+/=\-])[A-Za-z0-9_+/=\-]{32,}(?![A-Za-z0-9_+/=\-])"#, check: looksRandom),
    ]

    public static func find(in text: String) -> [Match] {
        let ns = text as NSString
        var found: [(kind: String, range: NSRange)] = []
        for rule in rules {
            for result in rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = result.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if let check = rule.check, !check(ns.substring(with: range)) { continue }
                // Skip anything an earlier, more specific rule already hid.
                if found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { continue }
                found.append((rule.kind, range))
            }
        }
        return found
            .sorted { $0.range.location < $1.range.location }
            .compactMap { item in Range(item.range, in: text).map { Match(kind: item.kind, range: $0) } }
    }

    // MARK: Checks

    /// "password: ********" or "token = <your token>" isn't a secret.
    static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        if Set(value).count <= 2 { return true } // ******, xxxxxx
        let words = ["your", "example", "placeholder", "changeme", "redacted", "xxxx", "<", "${", "{{", "process.env", "os.environ", "env("]
        return words.contains { lower.contains($0) }
    }

    /// 13 digits: YYMMDD birth date, then a Luhn check digit.
    static func isSouthAfricanID(_ digits: String) -> Bool {
        let d = digits.compactMap(\.wholeNumberValue)
        guard d.count == 13 else { return false }
        let month = d[2] * 10 + d[3], day = d[4] * 10 + d[5]
        guard (1...12).contains(month), (1...31).contains(day), d[10] <= 1 else { return false }
        return luhn(d)
    }

    static func isCardNumber(_ text: String) -> Bool {
        let d = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(d.count), Set(d).count > 2 else { return false }
        return luhn(d)
    }

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Long, mixed and random-looking: letters and digits, upper and lower
    /// case, and more than 4.2 bits of entropy per character. Hex hashes
    /// (git SHAs) top out at 4 bits, so they don't count; words and paths
    /// don't mix like this.
    static func looksRandom(_ s: String) -> Bool {
        guard s.count >= 32 else { return false }
        let hasDigit = s.contains { $0.isNumber }
        let hasUpper = s.contains { $0.isUppercase }
        let hasLower = s.contains { $0.isLowercase }
        guard hasDigit, hasUpper, hasLower else { return false }
        return entropy(s) > 4.2
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / n
            return sum - p * log2(p)
        }
    }
}
