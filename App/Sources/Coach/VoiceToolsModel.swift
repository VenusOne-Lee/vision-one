import AVFoundation
import Foundation
import VisionOneKit

/// The optional ElevenLabs voice tools for one take: clean a noisy voice
/// and fix one word in the user's own cloned voice. Every change waits in
/// voice.json as a proposal with Keep and Undo; export uses kept ones.
@MainActor
final class VoiceToolsModel: ObservableObject {
    enum Work: Equatable { case idle, cleaning, cloning, fixing }

    let take: Take
    let coach = CoachServices.shared
    @Published private(set) var edits: VoiceEdits
    @Published private(set) var transcript: Transcript?
    @Published private(set) var work: Work = .idle
    @Published var problem: String?
    @Published var search = ""
    @Published var selectedWordID: Int?
    @Published var replacement = ""
    private var preview: AVPlayer?

    init(take: Take) {
        self.take = take
        edits = VoiceEdits.load(from: take.voiceURL)
        transcript = try? Transcript.read(from: take.transcriptURL)
    }

    var micSeconds: Double { transcript?.duration ?? 0 }

    private func save() {
        do { try edits.write(to: take.voiceURL) } catch { problem = "Couldn't save voice.json: \(error.localizedDescription)" }
        NotificationCenter.default.post(name: .voiceEditsChanged, object: take.folder)
    }

    // MARK: Voice isolator

    func cleanVoice() {
        problem = nil
        work = .cleaning
        let client = coach.client()
        let take = take
        Task {
            defer { work = .idle }
            do {
                let micURL = try await MicTrack.export(from: take)
                defer { try? FileManager.default.removeItem(at: micURL) }
                let data = try Data(contentsOf: micURL)
                let seconds = try await AVURLAsset(url: micURL).load(.duration).seconds
                let cleaned = try await client.isolate(audio: data, fileName: "mic.m4a", seconds: seconds)
                let name = "voice-clean.\(AudioFileKind.fileExtension(for: cleaned))"
                try cleaned.write(to: take.folder.appendingPathComponent(name), options: .atomic)
                if let old = edits.cleanVoice?.file, old != name {
                    try? FileManager.default.removeItem(at: take.folder.appendingPathComponent(old))
                }
                edits.cleanVoice = VoiceEdits.CleanVoice(file: name)
                save()
            } catch {
                problem = CoachServices.message(for: error)
            }
        }
    }

    func keepCleanVoice() {
        edits.cleanVoice?.kept = true
        save()
    }

    func undoCleanVoice() {
        if let file = edits.cleanVoice?.file {
            try? FileManager.default.removeItem(at: take.folder.appendingPathComponent(file))
        }
        edits.cleanVoice = nil
        save()
    }

    /// Plays a few seconds of the original mic or the cleaned voice.
    func preview(cleaned: Bool, at time: Double = 0) {
        preview?.pause()
        let url: URL
        if cleaned, let file = edits.cleanVoice?.file {
            url = take.folder.appendingPathComponent(file)
        } else {
            url = take.screenURL
        }
        let player = AVPlayer(url: url)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        player.play()
        preview = player
    }

    func stopPreview() {
        preview?.pause()
        preview = nil
    }

    // MARK: Fix a word

    var hasClone: Bool { !coach.cloneVoiceID.isEmpty }

    /// Words matching the search, or the least sure ones when it's empty.
    var candidates: [TranscriptWord] {
        guard let words = transcript?.words else { return [] }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            return Array(words.filter { ($0.confidence ?? 1) < 0.6 }.prefix(12))
        }
        return Array(words.filter { $0.normalized.contains(query) }.prefix(20))
    }

    var selectedWord: TranscriptWord? { selectedWordID.flatMap { transcript?.word(id: $0) } }

    /// Makes an instant voice clone from this take and up to two others,
    /// after the user agreed in the consent sheet.
    func makeClone() {
        problem = nil
        work = .cloning
        let client = coach.client()
        let takes = [take] + TakeLibrary.standard.takes().filter { $0.folder != take.folder }.prefix(2)
        Task {
            defer { work = .idle }
            var samples: [(fileName: String, data: Data)] = []
            var seconds = 0.0
            var urls: [URL] = []
            defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
            for (i, source) in takes.enumerated() {
                guard let url = try? await MicTrack.export(from: source, maxSeconds: 120),
                      let data = try? Data(contentsOf: url) else { continue }
                urls.append(url)
                samples.append(("take-\(i + 1).m4a", data))
                seconds += (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            }
            guard !samples.isEmpty else {
                problem = "Couldn't read your voice from these takes."
                return
            }
            do {
                coach.cloneVoiceID = try await client.cloneVoice(name: "My voice (Vision One)", samples: samples, seconds: seconds)
            } catch {
                problem = CoachServices.message(for: error)
            }
        }
    }

    /// Says the replacement in the user's cloned voice and proposes it.
    func fixWord() {
        guard let word = selectedWord, hasClone else { return }
        let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        problem = nil
        work = .fixing
        let client = coach.client()
        let voice = coach.cloneVoiceID
        let take = take
        Task {
            defer { work = .idle }
            do {
                let spoken = try await client.speak(text, voiceID: voice, model: ElevenLabsClient.speechModel,
                                                    task: .voiceFix, summary: "Say “\(text)” in your cloned voice")
                let name = "voice-fix-\(word.id).\(AudioFileKind.fileExtension(for: spoken.audio))"
                try spoken.audio.write(to: take.folder.appendingPathComponent(name), options: .atomic)
                let duration = spoken.duration > 0 ? spoken.duration
                    : ((try? await AVURLAsset(url: take.folder.appendingPathComponent(name)).load(.duration).seconds) ?? word.duration)
                edits.propose(VoiceEdits.WordFix(wordID: word.id, start: word.start, end: word.end, original: word.text,
                                                 replacement: text, file: name, duration: duration, voiceID: voice))
                save()
                replacement = ""
            } catch {
                problem = CoachServices.message(for: error)
            }
        }
    }

    func hearFix(_ fix: VoiceEdits.WordFix) {
        preview?.pause()
        let player = AVPlayer(url: take.folder.appendingPathComponent(fix.file))
        player.play()
        preview = player
    }

    func keepFix(_ fix: VoiceEdits.WordFix) {
        edits.keep(fix.id)
        save()
    }

    func undoFix(_ fix: VoiceEdits.WordFix) {
        if let file = edits.undo(fix.id) {
            try? FileManager.default.removeItem(at: take.folder.appendingPathComponent(file))
        }
        save()
    }
}

extension Notification.Name {
    /// Posted with the take folder when voice.json changes, so the
    /// transcript can mark AI-spoken words.
    static let voiceEditsChanged = Notification.Name("VisionOneVoiceEditsChanged")
}

/// The mic track of a take on its own, as M4A, on the take's clock: the
/// file starts at the recording's first frame, so the cleaned voice that
/// comes back lines up without shifting.
enum MicTrack {
    enum Failure: LocalizedError {
        case noMic, exportFailed
        var errorDescription: String? {
            switch self {
            case .noMic: return "This take has no mic track."
            case .exportFailed: return "Couldn't copy the mic track."
            }
        }
    }

    /// Index of the mic among screen.mov's audio tracks.
    static func micIndex(of tracks: [AVAssetTrack], take: Take) async -> Int? {
        var counts: [Int] = []
        for track in tracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let channels = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            counts.append(Int(channels ?? 0))
        }
        let recorded = try? TakeAudioTracks.read(from: take.audioTracksURL)
        return TakeAudioTracks.sources(recorded: recorded, channelCounts: counts).firstIndex(of: .mic)
    }

    static func export(from take: Take, maxSeconds: Double? = nil) async throws -> URL {
        let asset = AVURLAsset(url: take.screenURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let index = await micIndex(of: tracks, take: take) else { throw Failure.noMic }
        let mic = tracks[index]
        var range = try await mic.load(.timeRange)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportFailed
        }
        if let maxSeconds, range.duration.seconds > maxSeconds {
            range = CMTimeRange(start: range.start, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        }
        // At its own start time, so silence before it keeps the clock.
        try track.insertTimeRange(range, of: mic, at: maxSeconds == nil ? range.start : .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.exportFailed
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vision-one-mic-\(UUID().uuidString).m4a")
        try await session.export(to: url, as: .m4a)
        return url
    }
}
