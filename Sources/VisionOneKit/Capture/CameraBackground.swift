import Foundation

/// What sits behind the person in the camera bubble. camera.mov is always
/// recorded clean; the background is drawn on top of it, live in the
/// bubble and again at export, so it can be changed after recording.
/// A take keeps its choice in background.json.
public struct CameraBackground: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// The real room, as the camera saw it.
        case off
        /// The real room, blurred like a lens.
        case blur
        /// One of the rooms drawn by Vision One (`room`).
        case room
        /// A picture the person chose (`picture`, in the Backgrounds folder).
        case picture
    }

    public var version = 1
    public var style: Style
    /// Set when `style` is `.room`.
    public var room: RoomID?
    /// A file name in `CameraBackground.picturesFolder`, when `style` is
    /// `.picture`. Copied there so takes keep working if the original moves.
    public var picture: String?
    /// Colour, light wrap, lens blur, grain and shadow, so the person
    /// looks lit by the room. On by default.
    public var matchLight: Bool
    /// The room shifts a little as the person moves, near things more
    /// than far things, like a camera gently following them.
    public var moveWithMe: Bool

    public init(style: Style = .off, room: RoomID? = nil, picture: String? = nil,
                matchLight: Bool = true, moveWithMe: Bool = false) {
        self.style = style
        self.room = room
        self.picture = picture
        self.matchLight = matchLight
        self.moveWithMe = moveWithMe
    }

    public static let off = CameraBackground()

    public static func room(_ id: RoomID) -> CameraBackground {
        CameraBackground(style: .room, room: id)
    }

    /// Anything to draw? A room without its id or a picture without its
    /// file draws nothing.
    public var isOn: Bool {
        switch style {
        case .off: return false
        case .blur: return true
        case .room: return room != nil
        case .picture: return picture != nil
        }
    }

    /// Only a room or picture replaces the real room; these switches do
    /// nothing for Off and Blur.
    public var replacesRoom: Bool { isOn && (style == .room || style == .picture) }

    /// "Loft", "Blur", "Your picture".
    public var title: String {
        switch style {
        case .off: return "Off"
        case .blur: return "Blur"
        case .room: return room?.title ?? "Off"
        case .picture: return picture == nil ? "Off" : "Your picture"
        }
    }

    /// The same choice with a new style, keeping the two switches.
    public func with(style: Style, room: RoomID? = nil, picture: String? = nil) -> CameraBackground {
        var copy = self
        copy.style = style
        copy.room = style == .room ? room : nil
        copy.picture = style == .picture ? picture : nil
        return copy
    }

    // A missing key falls back to the default, so files from older
    // versions (or written by hand) still read.
    private enum CodingKeys: String, CodingKey { case version, style, room, picture, matchLight, moveWithMe }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? .off
        room = try? c.decodeIfPresent(RoomID.self, forKey: .room)
        picture = try c.decodeIfPresent(String.self, forKey: .picture)
        matchLight = try c.decodeIfPresent(Bool.self, forKey: .matchLight) ?? true
        moveWithMe = try c.decodeIfPresent(Bool.self, forKey: .moveWithMe) ?? false
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The take's choice, or Off when it has none.
    public static func read(from url: URL) -> CameraBackground {
        guard let data = try? Data(contentsOf: url),
              let background = try? JSONDecoder().decode(CameraBackground.self, from: data) else { return .off }
        return background
    }

    /// ~/Library/Application Support/Vision One/Backgrounds
    public static var picturesFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vision One/Backgrounds", isDirectory: true)
    }

    /// ~/Library/Application Support/Vision One/Models, for the depth model.
    public static var modelsFolder: URL {
        picturesFolder.deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true)
    }

    /// The picture's file, when this is a picture background.
    public var pictureURL: URL? {
        guard style == .picture, let picture, !picture.isEmpty,
              !picture.contains("/"), !picture.hasPrefix(".") else { return nil }
        return Self.picturesFolder.appendingPathComponent(picture)
    }
}

extension Take {
    /// The camera background chosen for this take (`CameraBackground`).
    public var backgroundURL: URL { folder.appendingPathComponent("background.json") }
}
