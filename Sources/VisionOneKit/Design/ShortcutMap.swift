import Foundation

/// One keyboard shortcut: what it does, which menu it lives in, and its
/// keys. Menus, button tooltips and the Keyboard Shortcuts window all
/// read the same entry, so they can't drift apart.
public struct ShortcutSpec: Sendable, Hashable, Identifiable {
    public enum Modifier: String, Sendable, Hashable, CaseIterable {
        // In the order macOS prints them: ⌃⌥⇧⌘.
        case control, option, shift, command

        public var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    /// Keys that aren't a printable character.
    public enum Key: Sendable, Hashable {
        case character(Character)
        case space, `return`, delete, escape, leftArrow, rightArrow

        public var symbol: String {
            switch self {
            case .character(let c): String(c).uppercased()
            case .space: "Space"
            case .return: "⏎"
            case .delete: "⌫"
            case .escape: "⎋"
            case .leftArrow: "←"
            case .rightArrow: "→"
            }
        }
    }

    public let id: String
    public let title: String
    public let menu: String
    public let key: Key
    public let modifiers: Set<Modifier>
    /// Works from any app (a system-wide hot key), not just in Vision One.
    public let isGlobal: Bool

    public init(_ id: String, _ title: String, menu: String, key: Key,
                modifiers: Set<Modifier> = [], isGlobal: Bool = false) {
        self.id = id
        self.title = title
        self.menu = menu
        self.key = key
        self.modifiers = modifiers
        self.isGlobal = isGlobal
    }

    /// "⇧⌘R", the way macOS menus print it.
    public var display: String {
        Modifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + key.symbol
    }

    /// Identity of the keys pressed, for finding clashes.
    var chord: String {
        Modifier.allCases.filter(modifiers.contains).map(\.rawValue).joined(separator: "+") + "|\(key)"
    }
}

/// Every shortcut in Vision One. Standard macOS shortcuts (⌘Q, ⌘W, ⌘C…)
/// keep their usual meaning and aren't listed here.
public enum ShortcutMap {
    public static let record = ShortcutSpec("record", "Start or stop recording", menu: "Recording",
                                            key: .character("r"), modifiers: [.command, .shift], isGlobal: true)
    /// Loom's pause keys; ⇧⌘P is too many apps' command palette.
    public static let pauseRecording = ShortcutSpec("pauseRecording", "Pause or resume recording", menu: "Recording",
                                                    key: .character("p"), modifiers: [.option, .shift], isGlobal: true)
    public static let library = ShortcutSpec("library", "Show Library", menu: "File",
                                             key: .character("l"), modifiers: [.command, .shift])
    public static let export = ShortcutSpec("export", "Export", menu: "File",
                                            key: .character("e"), modifiers: [.command])
    public static let undo = ShortcutSpec("undo", "Undo", menu: "Edit",
                                          key: .character("z"), modifiers: [.command])
    public static let redo = ShortcutSpec("redo", "Redo", menu: "Edit",
                                          key: .character("z"), modifiers: [.command, .shift])
    public static let find = ShortcutSpec("find", "Find in transcript", menu: "Edit",
                                          key: .character("f"), modifiers: [.command])
    public static let cutWords = ShortcutSpec("cutWords", "Cut selected words", menu: "Edit", key: .delete)
    public static let showTakes = ShortcutSpec("showTakes", "Show or hide takes", menu: "View",
                                               key: .character("1"), modifiers: [.command])
    public static let showTranscript = ShortcutSpec("showTranscript", "Show or hide transcript", menu: "View",
                                                    key: .character("2"), modifiers: [.command])
    public static let showSound = ShortcutSpec("showSound", "Show or hide sound", menu: "View",
                                               key: .character("3"), modifiers: [.command])
    public static let focusVideo = ShortcutSpec("focusVideo", "Focus video", menu: "View",
                                                key: .character("0"), modifiers: [.command])
    public static let textBigger = ShortcutSpec("textBigger", "Bigger text", menu: "View",
                                                key: .character("+"), modifiers: [.command])
    public static let textSmaller = ShortcutSpec("textSmaller", "Smaller text", menu: "View",
                                                 key: .character("-"), modifiers: [.command])
    public static let playPause = ShortcutSpec("playPause", "Play or pause", menu: "Playback", key: .space)
    public static let back = ShortcutSpec("back", "Play backwards", menu: "Playback", key: .character("j"))
    public static let pause = ShortcutSpec("pause", "Pause", menu: "Playback", key: .character("k"))
    public static let forward = ShortcutSpec("forward", "Play forwards", menu: "Playback", key: .character("l"))
    public static let stepBack = ShortcutSpec("stepBack", "Step back", menu: "Playback", key: .leftArrow)
    public static let stepForward = ShortcutSpec("stepForward", "Step forward", menu: "Playback", key: .rightArrow)
    public static let acceptAll = ShortcutSpec("acceptAll", "Accept all suggestions", menu: "Review",
                                               key: .return, modifiers: [.command])
    public static let shortcuts = ShortcutSpec("shortcuts", "Keyboard shortcuts", menu: "Help",
                                               key: .character("/"), modifiers: [.command])

    public static let all: [ShortcutSpec] = [
        record, pauseRecording, library, export, undo, redo, find, cutWords,
        showTakes, showTranscript, showSound, focusVideo, textBigger, textSmaller,
        playPause, back, pause, forward, stepBack, stepForward, acceptAll, shortcuts,
    ]

    /// Menus in the order the app's menu bar shows them.
    public static let menus = ["Recording", "File", "Edit", "View", "Playback", "Review", "Help"]

    public static func spec(_ id: String) -> ShortcutSpec? { all.first { $0.id == id } }

    /// Chords macOS gives every app; nothing here may take one over.
    static let reserved: Set<String> = [
        "command|character(\"q\")", "command|character(\"w\")", "command|character(\"h\")",
        "command|character(\"m\")", "command|character(\"c\")", "command|character(\"v\")",
        "command|character(\"x\")", "command|character(\"a\")", "command|character(\",\")",
        "command|character(\"n\")", "command|character(\"o\")", "command|character(\"s\")",
        "command|character(\"p\")", "command|character(\"`\")", "command|space",
    ]

    /// Two entries on the same keys. Empty when the map is sound.
    public static func clashes(in specs: [ShortcutSpec] = all) -> [[String]] {
        Dictionary(grouping: specs, by: \.chord).values
            .filter { $0.count > 1 }
            .map { $0.map(\.id).sorted() }
    }

    /// Entries that take a chord macOS reserves for something else.
    public static func reservedClashes(in specs: [ShortcutSpec] = all) -> [String] {
        specs.filter { reserved.contains($0.chord) }.map(\.id)
    }
}
