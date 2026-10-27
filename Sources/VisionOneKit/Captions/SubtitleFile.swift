import Foundation

/// Writes cues as SubRip (.srt) or WebVTT (.vtt) text. Times are output
/// time, so the file lines up with the exported video.
public enum SubtitleFile {
    public enum Format: String, CaseIterable, Sendable {
        case srt, vtt

        public var fileExtension: String { rawValue }
    }

    public static func string(_ cues: [CaptionCue], format: Format, wordTimings: Bool = false) -> String {
        switch format {
        case .srt: return srt(cues)
        case .vtt: return vtt(cues, wordTimings: wordTimings)
        }
    }

    /// SubRip: numbered blocks, comma before the milliseconds.
    public static func srt(_ cues: [CaptionCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
            out += cue.text + "\n\n"
        }
        return out
    }

    /// WebVTT. With `wordTimings`, each word after the first carries its
    /// start time (`<00:00:01.200>`), which players use for karaoke-style
    /// highlighting and Resolve and YouTube ignore safely.
    public static func vtt(_ cues: [CaptionCue], wordTimings: Bool = false) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n"
            var first = true
            let lines = cue.lines.map { line -> String in
                line.map { word -> String in
                    let text = escaped(word.text)
                    defer { first = false }
                    if wordTimings, !first, word.start > cue.start, word.start < cue.end {
                        return "<\(timestamp(word.start, separator: "."))>\(text)"
                    }
                    return text
                }.joined(separator: " ")
            }
            out += lines.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    /// HH:MM:SS,mmm (SRT) or HH:MM:SS.mmm (VTT).
    public static func timestamp(_ seconds: Double, separator: String) -> String {
        let totalMilliseconds = max(0, Int((seconds * 1000).rounded()))
        let ms = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Writes `captions.srt` or `captions.vtt` (or `name.srt`) into a folder.
    @discardableResult
    public static func write(
        _ cues: [CaptionCue], format: Format, to folder: URL, name: String = "captions", wordTimings: Bool = false
    ) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        try string(cues, format: format, wordTimings: wordTimings).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
