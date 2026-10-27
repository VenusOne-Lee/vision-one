import Foundation

/// The music bed under a take: one of Vision One's own sounds, or a
/// file the user chose.
public struct MusicBed: Codable, Equatable, Sendable {
    /// A built-in sound's id, such as "still-water". Nil for a file.
    public var libraryID: String?
    /// Absolute path of the user's own audio file. Nil when built in.
    public var filePath: String?
    public var title: String
    /// Where it came from and what its licence allows, shown under the
    /// picker so nobody forgets.
    public var licence: String
    /// Level of the bed while nobody is talking, in dB. 0 plays the file
    /// as it is.
    public var levelDB: Double
    /// How far the bed drops while someone talks, in dB.
    public var duckDB: Double
    /// Seconds to fade in at the start and out at the end of the video.
    public var fadeIn: Double
    public var fadeOut: Double
    /// Repeat the music to cover the whole video. Off plays it once.
    public var loops: Bool

    public static let defaultLevelDB = -14.0
    public static let defaultDuckDB = 12.0

    public init(libraryID: String? = nil, filePath: String? = nil, title: String, licence: String,
                levelDB: Double = MusicBed.defaultLevelDB, duckDB: Double = MusicBed.defaultDuckDB,
                fadeIn: Double = 1, fadeOut: Double = 2, loops: Bool = true) {
        self.libraryID = libraryID
        self.filePath = filePath
        self.title = title
        self.licence = licence
        self.levelDB = levelDB
        self.duckDB = duckDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.loops = loops
    }

    /// One of Vision One's own music beds.
    public static func library(_ sound: LibrarySound) -> MusicBed {
        MusicBed(libraryID: sound.id, title: sound.title, licence: SoundLibrary.licence)
    }

    /// The user's own file. They vouch for the rights.
    public static func file(at url: URL) -> MusicBed {
        MusicBed(filePath: url.path, title: url.deletingPathExtension().lastPathComponent,
                 licence: "Your own file. Only use music you have the rights to.")
    }
}

/// A sound effect pinned to a moment of the recording. Times are take
/// seconds, not output seconds, so an effect moves with the words around
/// it when you cut, and drops out if its own moment is cut.
public struct PlacedEffect: Codable, Equatable, Identifiable, Sendable {
    /// Dashed = suggested, solid = accepted, like cuts. Rejected ones stay
    /// in the list so suggestions don't bring them back.
    public enum State: String, Codable, Sendable {
        case proposed, accepted, rejected
    }

    public static let defaultLevelDB = -10.0

    public let id: UUID
    /// A built-in effect's id, such as "whoosh".
    public var soundID: String
    /// Where the sound starts, in seconds from the take's first frame.
    public var at: Double
    public var levelDB: Double
    public var state: State
    /// The user placed or moved it. Suggestions never replace it.
    public var isManual: Bool

    public init(id: UUID = UUID(), soundID: String, at: Double, levelDB: Double = PlacedEffect.defaultLevelDB,
                state: State = .accepted, isManual: Bool = true) {
        self.id = id
        self.soundID = soundID
        self.at = at
        self.levelDB = levelDB
        self.state = state
        self.isManual = isManual
    }
}

/// The sound.json file in a take folder: music and sound effects over
/// the edit. Like edits.json it never changes the recording. The editor
/// preview and export both read it. See docs/SOUND.md.
public struct SoundPlan: Codable, Equatable, Sendable {
    public var version = 1
    public var music: MusicBed?
    public var effects: [PlacedEffect]
    /// The Energy dial setting the current suggestions came from.
    public var energy: Energy

    public init(music: MusicBed? = nil, effects: [PlacedEffect] = [], energy: Energy = .calm) {
        self.music = music
        self.effects = effects
        self.energy = energy
    }

    public var isEmpty: Bool { music == nil && !effects.contains { $0.state == .accepted } }

    // MARK: Changing effects

    public mutating func setState(_ state: PlacedEffect.State, for id: UUID) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        effects[i].state = state
    }

    public mutating func acceptAllProposed() {
        for i in effects.indices where effects[i].state == .proposed {
            effects[i].state = .accepted
        }
    }

    public mutating func remove(id: UUID) {
        effects.removeAll { $0.id == id }
    }

    /// Moves an effect to another moment of the take. A moved effect
    /// counts as the user's own and is accepted.
    public mutating func move(id: UUID, to at: Double, sourceDuration: Double) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        effects[i].at = min(max(0, at), max(0, sourceDuration))
        effects[i].isManual = true
        effects[i].state = .accepted
    }

    // MARK: File

    public static func read(from url: URL) throws -> SoundPlan {
        try JSONDecoder().decode(SoundPlan.self, from: Data(contentsOf: url))
    }

    /// Reads sound.json, or an empty plan when the take has none.
    public static func load(from url: URL) throws -> SoundPlan {
        guard FileManager.default.fileExists(atPath: url.path) else { return SoundPlan() }
        return try read(from: url)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension Take {
    /// Music and sound effects; see `SoundPlan`.
    public var soundURL: URL { folder.appendingPathComponent("sound.json") }
}
