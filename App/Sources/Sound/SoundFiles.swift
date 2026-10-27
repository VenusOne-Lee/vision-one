import Foundation
import VisionOneKit

/// Where Vision One's own sounds live once made. Each one is rendered
/// from its recipe the first time it's needed and kept in
/// ~/Library/Application Support/Vision One/Sounds.
enum SoundFiles {
    enum Failure: LocalizedError {
        case unknownSound(String)
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case let .unknownSound(id): return "Vision One doesn't have a sound called \(id)."
            case let .missingFile(path): return "The music file isn't there any more: \(path)"
            }
        }
    }

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Vision One/Sounds", isDirectory: true)
    }

    /// The file for a library sound, made now if it isn't cached yet.
    static func url(forLibrarySound id: String) async throws -> URL {
        let folder = folder
        let url = folder.appendingPathComponent(SoundLibrary.fileName(for: id))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // Rendering a music bed takes a moment; keep it off the main thread.
        return try await Task.detached(priority: .userInitiated) {
            guard let samples = SoundSynth.render(id) else { throw Failure.unknownSound(id) }
            let data = WAVFile.data(samples: samples, sampleRate: Int(SoundSynth.sampleRate))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    /// The file a music bed plays.
    static func url(for bed: MusicBed) async throws -> URL {
        if let id = bed.libraryID { return try await url(forLibrarySound: id) }
        let path = bed.filePath ?? ""
        guard FileManager.default.fileExists(atPath: path) else { throw Failure.missingFile(path) }
        return URL(fileURLWithPath: path)
    }
}
