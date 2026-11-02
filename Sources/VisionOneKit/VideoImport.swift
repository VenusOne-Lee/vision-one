import Foundation

/// Copies validated media into a take without exposing a half-imported recording.
/// AVFoundation validation belongs to the app; this transaction is testable without it.
public enum VideoImport {
    public static func copy(_ source: URL, into library: TakeLibrary,
                            checkCancellation: () throws -> Void = {}) throws -> Take {
        let fm = FileManager.default
        let staging = library.folder.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = Take(folder: staging)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fm.createFile(atPath: staged.screenURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: staged.screenURL)
        defer { try? output.close() }
        while true {
            try checkCancellation()
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        try staged.setTitle(source.deletingPathExtension().lastPathComponent)
        try checkCancellation()
        let take = try library.newTake()
        do {
            // Move each file on the same volume; screen.mov lands last.
            try fm.moveItem(at: staged.titleURL, to: take.titleURL)
            try fm.moveItem(at: staged.screenURL, to: take.screenURL)
            return take
        } catch {
            try? fm.removeItem(at: take.folder)
            throw error
        }
    }
}
