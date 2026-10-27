import Foundation

extension FillerLexicon {
    /// Fillers for a take spoken in `language`. Hesitations (um, eh, hm)
    /// count in every language. Afrikaans and isiZulu add their own
    /// fillers, all as "maybe", so a word is only proposed when it stands
    /// on its own between pauses. Other languages count hesitations and
    /// the Mzansi words people mix in (eish, yoh) until a speaker helps us
    /// list theirs.
    public static func lexicon(for language: SALanguage) -> FillerLexicon {
        switch language {
        case .english: return .standard
        case .afrikaans: return FillerLexicon(entries: afrikaans + mzansi)
        case .zulu: return FillerLexicon(entries: zulu + mzansi)
        default: return FillerLexicon(entries: mzansi)
        }
    }

    /// Words mixed into speech in every South African language.
    static let mzansi: [FillerEntry] = [
        FillerEntry("eish", .maybe),
        FillerEntry("yoh", .maybe),
        FillerEntry("haai", .maybe),
        FillerEntry("sho", .maybe),
        FillerEntry("ne", .maybe, position: .endOfSentence),
        FillerEntry("neh", .maybe, position: .endOfSentence),
    ]

    static let afrikaans: [FillerEntry] = [
        FillerEntry("jy weet", .maybe),     // you know
        FillerEntry("ek meen", .maybe),     // I mean
        FillerEntry("soos", .maybe),        // like
        FillerEntry("basies", .maybe),      // basically
        FillerEntry("eintlik", .maybe),     // actually
        FillerEntry("nou ja", .maybe),      // well then
        FillerEntry("okei", .maybe),
        FillerEntry("ag", .maybe),
        FillerEntry("nê", .maybe, position: .endOfSentence),
    ]

    static let zulu: [FillerEntry] = [
        FillerEntry("uyabona", .maybe),     // you see
        FillerEntry("yazi", .maybe),        // you know
        FillerEntry("manje", .maybe),       // now, so
        FillerEntry("phela", .maybe),       // after all, you see
        FillerEntry("angithi", .maybe, position: .endOfSentence), // isn't it
    ]
}
