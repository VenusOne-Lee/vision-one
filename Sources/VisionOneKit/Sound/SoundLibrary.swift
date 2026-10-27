import Foundation

/// A sound that ships with Vision One. None of them are files in the
/// repo: `SoundSynth` makes each one from a recipe the first time it is
/// needed, so there is nothing to licence or credit.
public struct LibrarySound: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case music, effect
    }

    public let id: String
    public let title: String
    public let kind: Kind
    /// One line for the picker, such as "calm pad".
    public let summary: String
    /// Seconds of one render. Music beds loop seamlessly at this length.
    public let duration: Double
}

public enum SoundLibrary {
    public static let licence = "Vision One original, made in code. Free to use anywhere, no credit needed."

    /// Bump when a recipe changes so cached renders are made again.
    public static let recipeVersion = 1

    public static let music: [LibrarySound] = [
        LibrarySound(id: "still-water", title: "Still water", kind: .music, summary: "calm pad",
                     duration: SoundSynth.MusicRecipe.stillWater.loopDuration),
        LibrarySound(id: "workbench", title: "Workbench", kind: .music, summary: "soft pulse",
                     duration: SoundSynth.MusicRecipe.workbench.loopDuration),
        LibrarySound(id: "launch-day", title: "Launch day", kind: .music, summary: "upbeat",
                     duration: SoundSynth.MusicRecipe.launchDay.loopDuration),
    ]

    public static let effects: [LibrarySound] = [
        LibrarySound(id: "whoosh", title: "Whoosh", kind: .effect, summary: "a new topic", duration: 0.7),
        LibrarySound(id: "pop", title: "Pop", kind: .effect, summary: "something appears", duration: 0.15),
        LibrarySound(id: "click", title: "Click", kind: .effect, summary: "a tap", duration: 0.05),
        LibrarySound(id: "ding", title: "Ding", kind: .effect, summary: "done, it works", duration: 1.2),
        LibrarySound(id: "rise", title: "Rise", kind: .effect, summary: "build up to a reveal", duration: 1.4),
        LibrarySound(id: "thud", title: "Thud", kind: .effect, summary: "a big moment", duration: 0.5),
    ]

    public static func sound(id: String) -> LibrarySound? {
        music.first { $0.id == id } ?? effects.first { $0.id == id }
    }

    /// File name for a cached render.
    public static func fileName(for id: String) -> String {
        "\(id)-v\(recipeVersion).wav"
    }
}
