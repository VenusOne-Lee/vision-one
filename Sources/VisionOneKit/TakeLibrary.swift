import Foundation

/// One recording session. Every source gets its own track so the editor
/// can work on each one, and export combines them into one video.
///
///     Vision One 2026-10-27 at 10.53.12/
///       screen.mov    video + system sound track + mic track (fragmented)
///       events.json   cursor moves and clicks, timed from the first frame
///       transcript.json  word-timed transcript of the mic track
///       edits.json       cuts made in the editor; screen.mov is never changed
///       sound.json       music and sound effects over the edit
///       clips.json       short clips suggested or kept for social apps
///       thumbnails/      thumbnail.json and the saved thumbnail images
///       camera.mov    (next) camera, drawn in the ring bubble at export
///       phone.mov     iPhone screen + sound over USB, when one was recorded
///       Vision One 2026-10-27 at 10.53.12 (WhatsApp).mp4   exports
public struct Take: Equatable, Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var name: String { folder.lastPathComponent }
    public var screenURL: URL { folder.appendingPathComponent("screen.mov") }
    public var eventsURL: URL { folder.appendingPathComponent("events.json") }
    public var cameraURL: URL { folder.appendingPathComponent("camera.mov") }
    public var phoneURL: URL { folder.appendingPathComponent("phone.mov") }
    public var transcriptURL: URL { folder.appendingPathComponent("transcript.json") }
    public var editsURL: URL { folder.appendingPathComponent("edits.json") }
    public var clipsURL: URL { folder.appendingPathComponent("clips.json") }
    public var thumbnailsFolder: URL { folder.appendingPathComponent("thumbnails", isDirectory: true) }
    public var thumbnailDesignURL: URL { thumbnailsFolder.appendingPathComponent("thumbnail.json") }

    public func thumbnailURL(for size: ThumbnailSize) -> URL {
        thumbnailsFolder.appendingPathComponent(size.fileName)
    }

    /// "Vision One 2026-10-27 at 10.53.12 - Ship your first beta (vertical).mp4"
    public func clipURL(for clip: Clip) -> URL {
        let unsafe = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
        let words = clip.title
            .components(separatedBy: unsafe).joined()
            .replacingOccurrences(of: "…", with: "")
            .split(separator: " ")
            .prefix(6)
            .joined(separator: " ")
        let label = words.isEmpty ? "Clip" : words
        return folder.appendingPathComponent("\(name) - \(label) (\(clip.format.fileSuffix)).mp4")
    }

    /// Exports sit next to the recording, named after the take, so they
    /// read well once dragged out of the folder.
    public func exportURL(for preset: ExportPreset) -> URL {
        folder.appendingPathComponent("\(name)\(preset.fileSuffix).mp4")
    }
}

/// Decides where takes are saved and what they are called.
/// Default folder: ~/Movies/Vision One.
public struct TakeLibrary: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static var standard: TakeLibrary {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return TakeLibrary(folder: movies.appendingPathComponent("Vision One", isDirectory: true))
    }

    /// "Vision One 2026-10-27 at 10.53.12". Uses dots in the time, like
    /// macOS screenshots, because Finder shows colons as slashes.
    public static func takeName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Vision One \(formatter.string(from: date))"
    }

    /// Creates the folder for a new take without touching an existing one.
    public func newTake(at date: Date = Date(), fileManager: FileManager = .default) throws -> Take {
        let name = Self.takeName(for: date)
        var url = folder.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(n))", isDirectory: true)
            n += 1
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return Take(folder: url)
    }
}
