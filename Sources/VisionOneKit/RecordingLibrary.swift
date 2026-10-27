import Foundation

/// Decides where recordings are saved and what they are called.
/// Default folder: ~/Movies/Vision One.
public struct RecordingLibrary: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static var standard: RecordingLibrary {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return RecordingLibrary(folder: movies.appendingPathComponent("Vision One", isDirectory: true))
    }

    /// "Vision One 2026-10-27 at 10.53.12.mp4". Uses dots in the time,
    /// like macOS screenshots, because Finder shows colons as slashes.
    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Vision One \(formatter.string(from: date)).mp4"
    }

    /// A URL for a new recording that doesn't overwrite an existing file.
    public func newRecordingURL(at date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.fileName(for: date)
        var url = folder.appendingPathComponent(name)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            url = folder.appendingPathComponent("\(base) (\(n)).mp4")
            n += 1
        }
        return url
    }
}
