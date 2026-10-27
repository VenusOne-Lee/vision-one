import Foundation

extension CaptionWord {
    public init(_ word: TranscriptWord) {
        self.init(text: word.text, start: word.start, end: word.end)
    }
}

extension CaptionBuilder {
    /// Cues for a whole transcript. Pass EditList.outputTime(forSource:)
    /// as `outputTime` so cut words drop out and the rest are retimed.
    public func cues(
        for transcript: Transcript,
        outputTime: (Double) -> Double? = { $0 }
    ) -> [CaptionCue] {
        cues(for: transcript.words.map(CaptionWord.init), outputTime: outputTime)
    }
}

extension CaptionBuilder {
    /// Cues for the edited video: accepted cuts drop out, everything
    /// after them moves up. Proposed cuts don't count until accepted.
    public func cues(for transcript: Transcript, edits: EditList) -> [CaptionCue] {
        cues(for: transcript) { edits.outputTime(forSource: $0) }
    }
}

extension Take {
    /// captions.srt or captions.vtt in the take folder.
    public func captionsURL(_ format: SubtitleFile.Format) -> URL {
        folder.appendingPathComponent("captions").appendingPathExtension(format.fileExtension)
    }
}

extension Take {
    /// captions.json: the caption settings chosen for this take.
    public var captionSettingsURL: URL { folder.appendingPathComponent("captions.json") }

    /// Saved caption settings, or the defaults when there are none yet.
    public func loadCaptionSettings() -> CaptionSettings {
        guard let data = try? Data(contentsOf: captionSettingsURL),
              let settings = try? JSONDecoder().decode(CaptionSettings.self, from: data) else {
            return CaptionSettings()
        }
        return settings
    }

    public func saveCaptionSettings(_ settings: CaptionSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: captionSettingsURL, options: .atomic)
    }

    /// Captions for the edited take, from transcript.json and edits.json.
    public func captionCues(settings: CaptionSettings) throws -> [CaptionCue] {
        let transcript = try Transcript.read(from: transcriptURL)
        let edits = try EditList.load(from: editsURL, sourceDuration: transcript.duration)
        return settings.builder.cues(for: transcript, edits: edits)
    }

    /// Writes captions.srt and captions.vtt (with word timings) into
    /// `folder`, usually next to the exported video. Returns the files.
    @discardableResult
    public func writeCaptionFiles(settings: CaptionSettings, to folder: URL, name: String = "captions") throws -> [URL] {
        let cues = try captionCues(settings: settings)
        return try SubtitleFile.Format.allCases.map { format in
            try SubtitleFile.write(cues, format: format, to: folder, name: name, wordTimings: format == .vtt)
        }
    }
}
