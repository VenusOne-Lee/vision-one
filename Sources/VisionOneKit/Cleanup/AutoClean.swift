import Foundation

/// Runs the cleanup pass on a take once its transcript is written, and
/// adds the proposals to edits.json. Cuts the user already made, accepted
/// or rejected are kept, and nothing they rejected is proposed again.
public enum AutoClean {
    @discardableResult
    public static func run(on take: Take, transcript: Transcript, loudness: LoudnessEnvelope? = nil,
                           detector: CleanupDetector = CleanupDetector()) throws -> [Cut] {
        var list = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
        let added = list.propose(detector.proposals(for: transcript, loudness: loudness))
        try list.write(to: take.editsURL)
        return added
    }
}
