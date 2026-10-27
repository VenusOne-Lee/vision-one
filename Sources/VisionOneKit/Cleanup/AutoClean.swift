import Foundation

/// Runs the cleanup pass on a take once its transcript is written, and
/// adds the proposals to edits.json. Cuts the user already made, accepted
/// or rejected are kept, and nothing they rejected is proposed again.
public enum AutoClean {
    /// - Parameters:
    ///   - sourceDuration: Length of screen.mov. The transcript's duration
    ///     is the audio's length, which can be shorter than the video
    ///     (the mic stopped early), so the edit list and the dead air at
    ///     the end are measured against the video. Nil uses the
    ///     transcript's duration.
    ///   - loudness: Levels of the transcribed audio, for sharper pauses.
    @discardableResult
    public static func run(on take: Take, transcript: Transcript, sourceDuration: Double? = nil,
                           loudness: LoudnessEnvelope? = nil,
                           detector: CleanupDetector = CleanupDetector()) throws -> [Cut] {
        let duration = sourceDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? transcript.duration
        var list = try EditList.load(from: take.editsURL, sourceDuration: duration)
        let added = list.propose(detector.proposals(for: transcript.words, duration: duration, loudness: loudness))
        try list.write(to: take.editsURL)
        return added
    }
}
