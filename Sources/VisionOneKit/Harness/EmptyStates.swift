import Foundation

/// What the Changes panel says when it has no rows, so "nothing here"
/// never reads the same while the transcript is still being written, once
/// it's written and nothing stood out, and when there won't be one.
public enum ChangesEmptyState: Equatable, Sendable {
    /// No transcript yet and nothing has gone wrong: it's on its way.
    case transcribing
    /// The transcript is there and nothing was suggested.
    case noSuggestions
    /// There's no transcript and there won't be one without help: the
    /// take has transcript-failed.json, or transcribing it failed.
    case noTranscript(reason: String?)

    /// `failure` is why there's no transcript (the marker's message, the
    /// transcriber's, or the editor's own read error), nil when nothing
    /// has failed. A transcript that's there wins over an old failure.
    public static func resolve(hasTranscript: Bool, failure: String?) -> ChangesEmptyState {
        if hasTranscript { return .noSuggestions }
        if let failure {
            let clean = failure.trimmingCharacters(in: .whitespacesAndNewlines)
            return .noTranscript(reason: clean.isEmpty ? nil : clean)
        }
        return .transcribing
    }

    public var title: String {
        switch self {
        case .transcribing: return "Writing the transcript…"
        case .noSuggestions: return "Nothing to change."
        case .noTranscript: return "No transcript for this take."
        }
    }

    public var message: String {
        switch self {
        case .transcribing:
            return "Suggested cuts for ums and long pauses appear here when it's done. It all runs on this Mac."
        case .noSuggestions:
            return "The transcript is ready and nothing stood out to cut. Ask for anything else in the box below."
        case let .noTranscript(reason):
            return reason ?? "Nothing was heard in it, so there's nothing to suggest. Check your mic and record again."
        }
    }

    public var isError: Bool {
        if case .noTranscript = self { return true }
        return false
    }
}

/// The one-line "No AI is set up" note on New task. Shown only when every
/// rung has been checked and none is ready, and never again once the
/// builder closes it.
public enum AISetupNotice {
    /// `anyRungReady` is nil until the ladder has been checked.
    public static func isShown(anyRungReady: Bool?, dismissed: Bool) -> Bool {
        anyRungReady == false && !dismissed
    }

    public static let text = "No AI is set up yet. Recording, transcripts and trimming ums still work on this Mac."
    public static let action = "AI settings…"
}

extension TakeListing {
    /// The first words said in the take on one line, for the Library
    /// row; nil when there's no transcript or nothing was said. Runs of
    /// spaces and line breaks become one space, and a long line is cut at
    /// a word with "…".
    public func transcriptPreview(maxLength: Int = 140) -> String? {
        Self.preview(of: transcriptText, maxLength: maxLength)
    }

    static func preview(of text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > maxLength, maxLength > 1 else { return line }
        let cut = line.prefix(maxLength - 1)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        let trimmed = atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
        return (trimmed.isEmpty ? String(cut) : trimmed) + "…"
    }
}
