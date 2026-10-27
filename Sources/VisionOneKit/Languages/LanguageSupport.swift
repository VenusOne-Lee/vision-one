import Foundation

/// How well a job works in a language, shown next to it in the app so
/// nobody finds out after posting.
public enum LanguageQuality: Int, Comparable, Codable, Sendable {
    /// Not offered by any engine Vision One can use.
    case none = 0
    /// A starting point. A speaker should rewrite it.
    case rough = 1
    /// Usable. A speaker should check it before it's posted.
    case fair = 2
    case good = 3

    public static func < (a: LanguageQuality, b: LanguageQuality) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .none: return "Not available"
        case .rough: return "Rough"
        case .fair: return "Fair"
        case .good: return "Good"
        }
    }

    public var isAvailable: Bool { self != .none }

    /// Fair and rough results ask for a speaker to read them first.
    public var wantsSpeakerCheck: Bool { self == .fair || self == .rough }
}

/// One job in one language: how well, by which engine, and a short note.
public struct LanguageAbility: Equatable, Sendable {
    public var quality: LanguageQuality
    /// "Parakeet", "ElevenLabs Scribe", "Your AI rung", or "" for none.
    public var engine: String
    public var note: String

    public init(_ quality: LanguageQuality, _ engine: String = "", _ note: String = "") {
        self.quality = quality
        self.engine = engine
        self.note = note
    }

    public static let unavailable = LanguageAbility(.none)
}

/// What Vision One can do in each language, checked against each
/// provider's own docs on 27 Oct 2026 (docs/LANGUAGES.md has the
/// sources). Translation quality is an estimate for today's large
/// models, not a measured score.
public struct LanguageSupport: Equatable, Sendable {
    /// Speech to text on this Mac, free.
    public var transcribeOnMac: LanguageAbility
    /// Speech to text in the cloud (ElevenLabs Scribe, asks first).
    public var transcribeCloud: LanguageAbility
    /// Captions translated from English through the AI ladder.
    public var translate: LanguageAbility
    /// A dubbed sound track (ElevenLabs Dubbing, asks first).
    public var dub: LanguageAbility
    /// A script read aloud (ElevenLabs Eleven v4, asks first).
    public var speak: LanguageAbility
    /// The voice and script coach.
    public var coach: LanguageAbility

    /// The best way to get words for a take spoken in this language.
    public var transcribe: LanguageAbility {
        transcribeOnMac.quality >= transcribeCloud.quality ? transcribeOnMac : transcribeCloud
    }

    public static let scribe = "ElevenLabs Scribe"
    public static let dubbing = "ElevenLabs Dubbing"
    public static let voice = "ElevenLabs Eleven v4"
    public static let ladder = "Your AI rung"

    public static func of(_ language: SALanguage) -> LanguageSupport {
        let scribeModerate = LanguageAbility(.fair, scribe, "About 1 word in 3 to 4 wrong; fix them in the transcript")
        let dubV2 = LanguageAbility(.fair, dubbing, "New in Dubbing v2; ask a speaker to listen")
        let noDub = LanguageAbility(.none, "", "ElevenLabs doesn't dub this language yet")
        let noSpeech = LanguageAbility(.none, "", "No engine transcribes it yet; captions can still be translated from English")
        let coachFull = LanguageAbility(.fair, ladder, "Script rewrites and pace; fillers once the words are in")
        let coachScript = LanguageAbility(.rough, ladder, "Script rewrites and pace; no filler count yet")
        func translate(_ quality: LanguageQuality) -> LanguageAbility {
            LanguageAbility(quality, ladder, quality == .good ? "" : "Ask a speaker to check before posting")
        }
        switch language {
        case .english:
            return LanguageSupport(
                transcribeOnMac: LanguageAbility(.good, "Parakeet", "On this Mac, free"),
                transcribeCloud: LanguageAbility(.good, scribe),
                translate: LanguageAbility(.good, "", "The language you speak in"),
                dub: LanguageAbility(.good, dubbing),
                speak: LanguageAbility(.good, voice),
                coach: LanguageAbility(.good, "This Mac", "Live meters, script and fillers"))
        case .afrikaans:
            return LanguageSupport(
                transcribeOnMac: LanguageAbility(.none, "", "Whisper could, but it isn't in Vision One yet"),
                transcribeCloud: LanguageAbility(.fair, scribe, "About 1 word in 6 wrong"),
                translate: translate(.good),
                dub: LanguageAbility(.good, dubbing),
                speak: LanguageAbility(.good, voice),
                coach: coachFull)
        case .zulu:
            return LanguageSupport(transcribeOnMac: .unavailable, transcribeCloud: scribeModerate,
                                   translate: translate(.fair), dub: dubV2, speak: .unavailable, coach: coachFull)
        case .xhosa:
            return LanguageSupport(transcribeOnMac: .unavailable, transcribeCloud: scribeModerate,
                                   translate: translate(.fair), dub: noDub, speak: .unavailable, coach: coachScript)
        case .sepedi:
            return LanguageSupport(transcribeOnMac: .unavailable, transcribeCloud: scribeModerate,
                                   translate: translate(.fair), dub: dubV2, speak: .unavailable, coach: coachScript)
        case .sesotho, .setswana:
            return LanguageSupport(transcribeOnMac: .unavailable, transcribeCloud: noSpeech,
                                   translate: translate(.fair), dub: dubV2, speak: .unavailable, coach: coachScript)
        case .xitsonga, .siswati, .tshivenda:
            return LanguageSupport(transcribeOnMac: .unavailable, transcribeCloud: noSpeech,
                                   translate: translate(.rough), dub: dubV2, speak: .unavailable, coach: coachScript)
        case .ndebele:
            return LanguageSupport(transcribeOnMac: .unavailable, transcribeCloud: noSpeech,
                                   translate: translate(.rough), dub: noDub, speak: .unavailable, coach: coachScript)
        }
    }
}

extension SALanguage {
    public var support: LanguageSupport { LanguageSupport.of(self) }
}
