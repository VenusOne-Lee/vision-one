import Foundation

/// One recording session. Every source gets its own track so the editor
/// can work on each one, and export combines them into one video.
///
///     Vision One 2026-10-27 at 10.53.12/
///       screen.mov    video + system sound track + mic track (fragmented)
///       events.json   cursor moves and clicks, timed from the first frame
///       edits.json    cuts made in the editor; screen.mov is never changed
///       camera.mov    (next) camera, drawn in the ring bubble at export
public struct Take: Equatable, Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var name: String { folder.lastPathComponent }
    public var screenURL: URL { folder.appendingPathComponent("screen.mov") }
    public var eventsURL: URL { folder.appendingPathComponent("events.json") }
    public var cameraURL: URL { folder.appendingPathComponent("camera.mov") }
    public var editsURL: URL { folder.appendingPathComponent("edits.json") }
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
