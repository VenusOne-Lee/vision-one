import Foundation

/// Manual copy belongs to a take and destination, independently of generated
/// share.json. An empty string is an intentional edit, not a missing override.
public enum PostDrafts {
    public static func url(for take: Take) -> URL { take.folder.appendingPathComponent("post-drafts.json") }

    public static func read(for take: Take) throws -> [String: String] {
        let url = url(for: take)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    /// Read afresh so saving one network cannot overwrite another network's
    /// newer copy. Callers serialize edits on the UI actor.
    public static func save(_ text: String, destination: String, for take: Take) throws {
        var drafts = try read(for: take)
        drafts[destination] = text
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(drafts).write(to: url(for: take), options: .atomic)
    }
}

/// Shared eligibility for every automatic post-copy entry point.
public enum PostCopy {
    public static func canDraft(for take: Take) -> Bool {
        guard let transcript = try? Transcript.read(from: take.transcriptURL),
              let edits = try? EditList.load(from: take.editsURL, sourceDuration: transcript.duration) else { return false }
        return transcript.sentences(keeping: edits).reduce(0) { $0 + $1.wordIDs.count } >= SharerAgent.minimumWords
    }
}
