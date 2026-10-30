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

extension CaptionBuilder {
    /// Cues for the video export renders: words placed on the frame-snapped
    /// timeline, so captions stay on the frames where they're said however
    /// many cuts there are, then moved later by `offset` (a brand intro's
    /// length, for subtitle files).
    public func cues(for transcript: Transcript, timeline: ExportTimeline, offset: Double = 0) -> [CaptionCue] {
        cues(for: transcript) { source in timeline.outputTime(forSource: source).map { $0 + offset } }
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

    /// A visibility-only edit must merge with the latest saved style, position
    /// and language. Never replace those fields from a pane's cached copy.
    @discardableResult
    public func setCaptionVisibility(_ isOn: Bool) throws -> CaptionSettings {
        var settings: CaptionSettings
        if FileManager.default.fileExists(atPath: captionSettingsURL.path) {
            settings = try JSONDecoder().decode(CaptionSettings.self, from: Data(contentsOf: captionSettingsURL))
        } else { settings = CaptionSettings() }
        guard settings.isOn != isOn else { return settings }
        settings.isOn = isOn
        try saveCaptionSettings(settings)
        return settings
    }

    /// The words captions are made from: the translation in
    /// `settings.language` when the take has one, otherwise what was said.
    public func captionTranscript(language: SALanguage?) throws -> Transcript {
        if let language, FileManager.default.fileExists(atPath: transcriptURL(language: language).path) {
            return try Transcript.read(from: transcriptURL(language: language))
        }
        return try Transcript.read(from: transcriptURL)
    }

    /// Captions for the edited take, from transcript.json (or the chosen
    /// translation) and edits.json.
    public func captionCues(settings: CaptionSettings) throws -> [CaptionCue] {
        let transcript = try captionTranscript(language: settings.language)
        let edits = try EditList.load(from: editsURL, sourceDuration: transcript.duration)
        return settings.builder.cues(for: transcript, edits: edits)
    }

    /// Captions for one export, timed on the timeline it rendered and
    /// moved later by `offset` (the brand intro), from transcript.json
    /// or the chosen translation.
    public func captionCues(settings: CaptionSettings, timeline: ExportTimeline, offset: Double = 0) throws -> [CaptionCue] {
        let transcript = try captionTranscript(language: settings.language)
        return settings.builder.cues(for: transcript, timeline: timeline, offset: offset)
    }

    /// Writes captions.srt and captions.vtt (with word timings) into
    /// `folder`, usually next to the exported video. Returns the files.
    @discardableResult
    public func writeCaptionFiles(settings: CaptionSettings, to folder: URL, name: String = "captions") throws -> [URL] {
        try Self.writeSubtitles(captionCues(settings: settings), to: folder, name: name)
    }

    /// Writes the .srt and .vtt for one export, timed to match the video
    /// it made: the same timeline, moved later by the intro's length.
    /// Every other translated language gets its own pair too, named
    /// "<name>.zu.srt", so one export carries all of them.
    @discardableResult
    public func writeCaptionFiles(settings: CaptionSettings, timeline: ExportTimeline, offset: Double = 0,
                                  to folder: URL, name: String = "captions") throws -> [URL] {
        var urls = try Self.writeSubtitles(captionCues(settings: settings, timeline: timeline, offset: offset),
                                           to: folder, name: name)
        for language in captionLanguages() where language != settings.language {
            var other = settings
            other.language = language
            if let cues = try? captionCues(settings: other, timeline: timeline, offset: offset) {
                urls += (try? Self.writeSubtitles(cues, to: folder, name: "\(name).\(language.code)")) ?? []
            }
        }
        return urls
    }

    /// The names of the translated subtitle files written beside a
    /// video: "<name>.zu.srt" and ".vtt" for every caption language.
    public static func translatedSubtitleNames(for name: String) -> [String] {
        (SALanguage.captionTargets + [.english]).flatMap { language in
            SubtitleFile.Format.allCases.map { "\(name).\(language.code).\($0.fileExtension)" }
        }
    }

    private static func writeSubtitles(_ cues: [CaptionCue], to folder: URL, name: String) throws -> [URL] {
        try SubtitleFile.Format.allCases.map { format in
            try SubtitleFile.write(cues, format: format, to: folder, name: name, wordTimings: format == .vtt)
        }
    }
}
