import AppKit
import AVFoundation
import VisionOneKit

/// Captions in South Africa's languages, an optional dub, and Scribe for
/// takes spoken in a language Parakeet doesn't know. Translation goes
/// through the AI ladder; Scribe and dubbing through the user's own
/// ElevenLabs key. Everything that leaves the Mac asks first. See
/// docs/LANGUAGES.md.
@MainActor
final class LanguagesModel: ObservableObject {
    enum Work: Equatable {
        case idle
        case translating(SALanguage, Double)
        case transcribing(SALanguage)
        case dubbing(SALanguage, String)
        case failed(String)
        case done(String)

        var isBusy: Bool {
            switch self {
            case .translating, .transcribing, .dubbing: return true
            default: return false
            }
        }
    }

    let take: Take

    @Published private(set) var spoken: SALanguage = .english
    @Published private(set) var translated: [SALanguage] = []
    @Published private(set) var work: Work = .idle
    @Published var captionLanguage: SALanguage? {
        didSet {
            var settings = take.loadCaptionSettings()
            settings.language = captionLanguage
            try? take.saveCaptionSettings(settings)
        }
    }
    @Published var dubTarget: SALanguage = .afrikaans
    @Published private(set) var dubs: [SALanguage: URL] = [:]
    @Published var elevenLabsKey: String = ""

    private var task: Task<Void, Never>?

    init(take: Take) {
        self.take = take
        captionLanguage = take.loadCaptionSettings().language
        elevenLabsKey = AIServices.shared.key(AISecretName.elevenLabsKey)
        refresh()
    }

    var hasElevenLabs: Bool { !elevenLabsKey.isEmpty }

    /// Languages to offer captions in: everything but the one spoken.
    var targets: [SALanguage] {
        (SALanguage.captionTargets + [.english]).filter { $0 != spoken }
    }

    var dubTargets: [SALanguage] {
        SALanguage.allCases.filter { $0 != spoken && $0.support.dub.quality.isAvailable }
    }

    func refresh() {
        if let transcript = try? Transcript.read(from: take.transcriptURL) {
            spoken = SALanguage(code: transcript.language) ?? .english
        }
        translated = take.captionLanguages()
        var found: [SALanguage: URL] = [:]
        for language in SALanguage.allCases {
            let url = Self.dubbedVideoURL(for: take, language: language)
            if let url, FileManager.default.fileExists(atPath: url.path) { found[language] = url }
        }
        dubs = found
        if !dubTargets.contains(dubTarget), let first = dubTargets.first { dubTarget = first }
    }

    func saveKey() {
        AIServices.shared.setKey(elevenLabsKey, for: AISecretName.elevenLabsKey)
        elevenLabsKey = AIServices.shared.key(AISecretName.elevenLabsKey)
    }

    private var client: ElevenLabsClient {
        ElevenLabsClient(apiKey: AIServices.shared.key(AISecretName.elevenLabsKey), gate: AIServices.shared.gate)
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Captions

    func translate(_ language: SALanguage) {
        guard !work.isBusy else { return }
        let take = take
        let spoken = spoken
        let ladder = AIServices.shared.ladder()
        let brand = BrandStore.shared.kit
        let keywords = take.loadCaptionSettings().keywordNames
        let board = AIServices.shared.jobs
        let job = AgentJob(agent: .editor, title: "Captions in \(language.name)", take: take,
                           steps: ["Read the transcript", "Translate into \(language.name)", "Make the captions"])
        work = .translating(language, 0)
        task = Task {
            await board.add(job)
            do {
                await board.step(job.id, 0)
                let transcript = try Transcript.read(from: take.transcriptURL)
                let previous = try? TranslationFile.read(from: take.translationURL(language))
                await board.step(job.id, 1)
                let translator = CaptionTranslator(ladder: ladder)
                let file = try await translator.translate(
                    transcript, to: language, from: spoken,
                    keep: CaptionTranslator.keepAsIs(brand: brand, keywords: keywords),
                    context: brand.tagline, previous: previous) { fraction in
                        Task { @MainActor in
                            if case .translating(language, _) = self.work { self.work = .translating(language, fraction) }
                        }
                    }
                await board.step(job.id, 2)
                try take.saveTranslation(file, duration: transcript.duration, audioTrack: transcript.audioTrack)
                let receipt = AgentReceipt.translation(file)
                await board.finish(job.id, receipt: receipt, changes: [])
                work = .done(receipt)
            } catch is CancellationError {
                await board.cancel(job.id)
                work = .idle
            } catch {
                let message = AgentsModel.message(for: error)
                await board.fail(job.id, message)
                work = .failed(message)
            }
            refresh()
        }
    }

    func remove(_ language: SALanguage) {
        take.removeTranslation(language)
        if captionLanguage == language { captionLanguage = nil }
        refresh()
    }

    // MARK: Scribe

    /// Replaces transcript.json with Scribe's words in `language`. The
    /// Parakeet transcript is kept beside it as transcript.parakeet.json.
    func transcribe(in language: SALanguage) {
        guard !work.isBusy, language.support.transcribeCloud.quality.isAvailable else { return }
        let take = take
        let client = client
        work = .transcribing(language)
        task = Task {
            do {
                let audio = try await TakeAudio.read(take)
                let wav = WAVFile.data(samples: audio.samples, sampleRate: Int(TakeAudio.sampleRate))
                let transcript = try await client.transcribe(audio: wav, fileName: "voice.wav", mimeType: "audio/wav",
                                                             seconds: audio.duration, language: language,
                                                             audioTrack: audio.source.rawValue)
                let backup = take.folder.appendingPathComponent("transcript.parakeet.json")
                let fm = FileManager.default
                if fm.fileExists(atPath: take.transcriptURL.path), !fm.fileExists(atPath: backup.path) {
                    try? fm.copyItem(at: take.transcriptURL, to: backup)
                }
                try transcript.write(to: take.transcriptURL)
                work = .done("Transcribed \(transcript.words.count) words in \(language.name). Reopen the take in the editor to see them.")
            } catch is CancellationError {
                work = .idle
            } catch {
                work = .failed(AgentsModel.message(for: error))
            }
            refresh()
        }
    }

    // MARK: Dubbing

    /// The newest export of this take, which the dub is made from.
    static func latestExport(of take: Take) -> URL? {
        let fm = FileManager.default
        return ExportPreset.allCases.map { take.exportURL(for: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// "<export>.af.mp4" beside the export it was made from.
    static func dubbedVideoURL(for take: Take, language: SALanguage) -> URL? {
        guard let export = latestExport(of: take) else { return nil }
        let name = export.deletingPathExtension().lastPathComponent
        return export.deletingLastPathComponent().appendingPathComponent("\(name).\(language.code).mp4")
    }

    func dub() {
        guard !work.isBusy, let export = Self.latestExport(of: take),
              let output = Self.dubbedVideoURL(for: take, language: dubTarget) else {
            work = .failed("Export the video first. The dub is made from your newest export, so music and cuts match.")
            return
        }
        let target = dubTarget
        let spoken = spoken
        let take = take
        let client = client
        work = .dubbing(target, "Getting the sound ready")
        task = Task {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VisionOne-dub-\(UUID().uuidString)",
                                                                                     isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let sound = temp.appendingPathComponent("sound.m4a")
                try await DubMixer.audio(from: export, to: sound)
                let seconds = try await AVURLAsset(url: sound).load(.duration).seconds
                work = .dubbing(target, "ElevenLabs is dubbing it; this takes a few minutes")
                let dubbed = try await client.dub(audio: try Data(contentsOf: sound), fileName: "sound.m4a",
                                                  mimeType: "audio/mp4", seconds: seconds, from: spoken, to: target,
                                                  name: "Vision One · \(take.name) · \(target.name)")
                work = .dubbing(target, "Putting the dub on the video")
                let raw = temp.appendingPathComponent("dub.\(DubMixer.fileExtension(for: dubbed))")
                try dubbed.write(to: raw)
                let track = take.folder.appendingPathComponent("dub.\(target.code).m4a")
                try? FileManager.default.removeItem(at: track)
                try await DubMixer.audio(from: raw, to: track)
                try? FileManager.default.removeItem(at: output)
                try await DubMixer.replaceSound(of: export, with: track, to: output)
                work = .done("The \(target.name) version is ready: \(output.lastPathComponent). Its voice is AI-made from yours; say so where you post it.")
            } catch is CancellationError {
                work = .idle
            } catch {
                work = .failed(AgentsModel.message(for: error))
            }
            refresh()
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Moves sound between files for dubbing, without re-encoding the video.
enum DubMixer {
    enum Failure: LocalizedError {
        case couldNotExport(String)

        var errorDescription: String? {
            switch self {
            case let .couldNotExport(what): return "Couldn't \(what). Try exporting the video again first."
            }
        }
    }

    /// The sound of a video or audio file as AAC in an .m4a.
    static func audio(from source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.couldNotExport("read the sound")
        }
        try await session.export(to: output, as: .m4a)
    }

    /// The video of `video` with `sound` as its only audio, as an MP4.
    static func replaceSound(of video: URL, with sound: URL, to output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let soundAsset = AVURLAsset(url: sound)
        let composition = AVMutableComposition()
        let duration = try await videoAsset.load(.duration)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceSound = try await soundAsset.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let soundTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.couldNotExport("put the dub on the video")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let soundDuration = try await soundAsset.load(.duration)
        try soundTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, soundDuration)),
                                       of: sourceSound, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.couldNotExport("put the dub on the video")
        }
        try await session.export(to: output, as: .mp4)
    }

    /// ElevenLabs sends MP3 or MP4 audio; the extension lets AVFoundation
    /// open it.
    static func fileExtension(for data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.count >= 8, head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 { return "m4a" }
        return "mp3"
    }
}
