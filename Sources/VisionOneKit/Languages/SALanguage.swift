import Foundation

/// The 11 spoken official languages of South Africa. South African Sign
/// Language is the twelfth official language; it isn't spoken, so it has
/// no captions, translation or dub here (see docs/LANGUAGES.md).
public enum SALanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english = "en"
    case afrikaans = "af"
    case zulu = "zu"
    case xhosa = "xh"
    case sepedi = "nso"
    case sesotho = "st"
    case setswana = "tn"
    case xitsonga = "ts"
    case siswati = "ss"
    case tshivenda = "ve"
    case ndebele = "nr"

    public var id: String { rawValue }

    /// The code saved in files and sent to ElevenLabs: ISO 639-1 where
    /// there is one, ISO 639-3 for Sepedi.
    public var code: String { rawValue }

    /// ISO 639-3, which ElevenLabs Scribe answers with.
    public var iso3: String {
        switch self {
        case .english: return "eng"
        case .afrikaans: return "afr"
        case .zulu: return "zul"
        case .xhosa: return "xho"
        case .sepedi: return "nso"
        case .sesotho: return "sot"
        case .setswana: return "tsn"
        case .xitsonga: return "tso"
        case .siswati: return "ssw"
        case .tshivenda: return "ven"
        case .ndebele: return "nbl"
        }
    }

    /// The name South Africans use in English: "isiZulu", "Sepedi".
    public var name: String {
        switch self {
        case .english: return "English"
        case .afrikaans: return "Afrikaans"
        case .zulu: return "isiZulu"
        case .xhosa: return "isiXhosa"
        case .sepedi: return "Sepedi"
        case .sesotho: return "Sesotho"
        case .setswana: return "Setswana"
        case .xitsonga: return "Xitsonga"
        case .siswati: return "siSwati"
        case .tshivenda: return "Tshivenḓa"
        case .ndebele: return "isiNdebele"
        }
    }

    /// The name in the language itself, when it differs from `name`.
    public var ownName: String {
        switch self {
        case .sepedi: return "Sesotho sa Leboa"
        default: return name
        }
    }

    /// What a model should be told to write in. Spelled out so a model
    /// doesn't mix up Sesotho and Sepedi, or Ndebele of the south and
    /// of Zimbabwe.
    public var promptName: String {
        switch self {
        case .english: return "South African English"
        case .afrikaans: return "Afrikaans"
        case .zulu: return "isiZulu (Zulu)"
        case .xhosa: return "isiXhosa (Xhosa)"
        case .sepedi: return "Sepedi (Sesotho sa Leboa, Northern Sotho)"
        case .sesotho: return "Sesotho (Southern Sotho, as written in South Africa)"
        case .setswana: return "Setswana (Tswana, as written in South Africa)"
        case .xitsonga: return "Xitsonga (Tsonga)"
        case .siswati: return "siSwati (Swati)"
        case .tshivenda: return "Tshivenḓa (Venda)"
        case .ndebele: return "isiNdebele (South African Ndebele, not Zimbabwean)"
        }
    }

    /// The language for a code or name as people and services write it:
    /// "zu", "zul", "zu-ZA", "isiZulu", "Zulu", "Northern Sotho".
    public init?(code: String) {
        let raw = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        let base = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? raw
        let found = Self.allCases.first { language in
            [language.code, language.iso3, language.name.lowercased(), language.ownName.lowercased()].contains(base)
                || Self.aliases[base] == language
        }
        guard let found else { return nil }
        self = found
    }

    static let aliases: [String: SALanguage] = [
        "zulu": .zulu, "xhosa": .xhosa, "pedi": .sepedi, "northern sotho": .sepedi, "sesotho sa leboa": .sepedi,
        "sotho": .sesotho, "southern sotho": .sesotho, "tswana": .setswana, "tsonga": .xitsonga,
        "swati": .siswati, "swazi": .siswati, "venda": .tshivenda, "tshivenda": .tshivenda,
        "ndebele": .ndebele, "south ndebele": .ndebele, "southern ndebele": .ndebele,
        "south african english": .english,
    ]

    /// Every language except English, in the order the app lists them:
    /// the most spoken first (Stats SA census 2022, first language).
    public static let captionTargets: [SALanguage] = [
        .zulu, .xhosa, .afrikaans, .sepedi, .setswana, .sesotho, .xitsonga, .siswati, .tshivenda, .ndebele,
    ]
}
