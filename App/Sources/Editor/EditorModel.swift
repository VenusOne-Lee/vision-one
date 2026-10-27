import AVFoundation
import Combine
import VisionOneKit

/// One take open in the editor: its transcript, its edit list and the
/// preview player. Every change goes through `apply` so it can be undone
/// and is saved to edits.json straight away. screen.mov is never touched.
@MainActor
final class EditorModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum TranscriptState: Equatable {
        case loading
        /// No transcript.json yet; the editor checks again every few
        /// seconds, so it appears when transcription finishes.
        case waiting
        case ready
        case failed(String)
    }

    let take: Take
    let undoManager = UndoManager()
    let player = AVPlayer()
    /// Zooms and blurs, drawn into the preview by the export compositor.
    let effects: EffectsModel

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var transcriptState: TranscriptState = .loading
    @Published private(set) var transcript: Transcript?
    @Published private(set) var edits = EditList(sourceDuration: 0)
    /// Playhead, in seconds of the original take.
    @Published private(set) var sourceTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var saveError: String?
    /// Shape of the video, so boxes drawn over the preview line up.
    @Published private(set) var videoSize: CGSize = .zero

    /// Words in time order and their spans, cached from the transcript.
    private(set) var words: [TranscriptWord] = []
    private(set) var wordSpans: [TimeSpan] = []

    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    /// Every cut id this editor has seen, so cuts written by someone else
    /// (auto-clean runs right after transcription) can be told apart
    /// from cuts the user removed here.
    private var knownCutIDs = Set<UUID>()
    /// The preview as last built, so zooms and blurs can be redrawn
    /// without rebuilding it.
    private var preview: (composition: AVComposition, trackID: CMPersistentTrackID, renderSize: CGSize)?

    init(take: Take) {
        self.take = take
        effects = EffectsModel(take: take, undoManager: undoManager)
    }

    // MARK: Loading

    func load() async {
        let asset = AVURLAsset(url: take.screenURL)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                phase = .failed("This take has no video. It may still be saving, or the recording stopped before the first frame.")
                return
            }
            self.asset = asset
            edits = try EditList.load(from: take.editsURL, sourceDuration: duration)
            knownCutIDs = Set(edits.cuts.map(\.id))
        } catch {
            phase = .failed("Couldn't open this take: \(error.localizedDescription)")
            return
        }
        effects.onChange = { [weak self] in self?.refreshEffects() }
        effects.load(edits: edits)
        addTimeObserver()
        await rebuildPlayer()
        phase = .ready
        loadTranscript()
        startWatching()
    }

    /// Every two seconds: pick up the transcript when it lands, and any
    /// cuts auto-clean has written since.
    private func startWatching() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if self.transcriptState == .waiting { self.loadTranscript() }
                if self.mergeOutsideCuts() { self.scheduleRebuild() }
            }
        }
    }

    /// Adds cuts in edits.json that this editor has never seen. Returns
    /// true if any were added.
    @discardableResult
    private func mergeOutsideCuts() -> Bool {
        guard let disk = try? EditList.read(from: take.editsURL) else { return false }
        let new = disk.cuts.filter { !knownCutIDs.contains($0.id) }
        guard !new.isEmpty else { return false }
        edits.cuts += new
        knownCutIDs.formUnion(new.map(\.id))
        return true
    }

    private func loadTranscript() {
        guard FileManager.default.fileExists(atPath: take.transcriptURL.path) else {
            transcriptState = .waiting
            return
        }
        do {
            let transcript = try Transcript.read(from: take.transcriptURL)
            self.transcript = transcript
            words = transcript.words
            wordSpans = words.map(\.span)
            transcriptState = .ready
        } catch {
            transcriptState = .failed("The transcript couldn't be read: \(error.localizedDescription)")
        }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rebuildTask?.cancel()
        watch?.cancel()
        effects.close()
    }

    // MARK: Editing

    /// Deleting words cuts them; deleting words that are all already cut
    /// brings them back. `range` is word positions in `words`.
    func toggleCut(words range: ClosedRange<Int>) {
        guard let span = EditList.span(deleting: range, of: wordSpans, sourceDuration: edits.sourceDuration) else { return }
        let marks = edits.marks(for: Array(wordSpans[range]))
        var next = edits
        if marks.allSatisfy({ $0 == .cut }) {
            next.restore(span)
            apply(next, actionName: "Restore")
        } else {
            next.add(Cut(span: span, reason: Cut.Reason.word, state: .accepted))
            apply(next, actionName: "Cut")
        }
    }

    func acceptAllProposed() {
        var next = edits
        next.acceptAllProposed()
        apply(next, actionName: "Accept All")
    }

    var proposedCount: Int {
        edits.cuts.filter { $0.state == .proposed }.count
    }

    private func apply(_ next: EditList, actionName: String) {
        let previous = edits
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        edits = next
        knownCutIDs.formUnion(next.cuts.map(\.id))
        save()
        scheduleRebuild()
    }

    private func save() {
        // Keep cuts auto-clean wrote since the last look, instead of
        // writing over them.
        mergeOutsideCuts()
        do {
            try edits.write(to: take.editsURL)
            saveError = nil
        } catch {
            saveError = "Couldn't save your edits: \(error.localizedDescription)"
        }
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        if let item = player.currentItem, CMTimeCompare(item.currentTime(), item.duration) >= 0 {
            seek(toSource: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// J, K and L: back five seconds, stop, play.
    func skip(by seconds: Double) {
        let output = (edits.outputTime(forSource: sourceTime) ?? 0) + seconds
        seek(toSource: edits.sourceTime(forOutput: max(0, output)))
    }

    /// Moves the playhead to a moment of the take. Inside a cut, it lands
    /// on the first frame after the cut.
    func seek(toSource t: Double) {
        let source = edits.nearestKeptSource(min(max(0, t), edits.sourceDuration))
        let output = edits.outputTime(forSource: source) ?? edits.outputDuration
        sourceTime = source
        player.seek(to: CMTime(seconds: output, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Word position being spoken at the playhead, for the ink underline.
    var playingWordIndex: Int? {
        wordSpans.firstIndex { $0.start <= sourceTime && sourceTime < $0.end }
    }

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sourceTime = self.edits.sourceTime(forOutput: time.seconds)
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            // Let a burst of edits (holding Delete, Undo) settle first.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.rebuildPlayer()
        }
    }

    /// Swaps in a new preview of the kept spans, keeping the playhead on
    /// the same moment of the take and playing on if it was playing.
    private func rebuildPlayer() async {
        guard let asset else { return }
        let wasPlaying = isPlaying
        let keep = sourceTime
        do {
            let composition = try await PreviewComposition.make(from: asset, keeping: edits.keptSpans)
            guard !Task.isCancelled else { return }
            if let track = composition.tracks(withMediaType: .video).first {
                let natural = try await track.load(.naturalSize)
                // Big enough to judge a blur, small enough to play smoothly.
                let scale = min(1, 1920 / max(natural.width, natural.height, 1))
                let size = CGSize(width: (natural.width * scale / 2).rounded() * 2,
                                  height: (natural.height * scale / 2).rounded() * 2)
                preview = (composition, track.trackID, size)
                videoSize = natural
            } else {
                preview = nil
            }
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = previewVideoComposition()
            player.replaceCurrentItem(with: item)
            seek(toSource: keep)
            if wasPlaying { player.play() }
        } catch {
            phase = .failed("Couldn't prepare the preview: \(error.localizedDescription)")
        }
    }
}

extension EditorModel {
    /// Redraws zooms and blurs on the current preview, keeping its place.
    func refreshEffects() {
        player.currentItem?.videoComposition = previewVideoComposition()
    }

    /// The export compositor, drawing this take's zooms and blurs, or nil
    /// to play the frames as they are.
    fileprivate func previewVideoComposition() -> AVVideoComposition? {
        guard let preview, preview.renderSize.width > 0,
              let effects = effects.previewEffects(edits: edits) else { return nil }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = FrameCompositor.self
        composition.renderSize = preview.renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [
            FrameInstruction(timeRange: CMTimeRange(start: .zero, duration: preview.composition.duration),
                             trackID: preview.trackID, overlays: [], effects: effects),
        ]
        return composition
    }
}

/// The preview is a composition of the kept spans of every track, the
/// same spans export renders, so what you hear is what you get. It only
/// points at screen.mov, so rebuilding it after an edit is quick.
enum PreviewComposition {
    static func make(from asset: AVAsset, keeping spans: [TimeSpan]) async throws -> AVComposition {
        let composition = AVMutableComposition()
        let scale: CMTimeScale = 60_000
        for track in try await asset.load(.tracks) {
            guard track.mediaType == .video || track.mediaType == .audio,
                  let output = composition.addMutableTrack(withMediaType: track.mediaType,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let trackRange = try await track.load(.timeRange)
            var outputStart = 0.0
            for span in spans {
                let wanted = CMTimeRange(start: CMTime(seconds: span.start, preferredTimescale: scale),
                                         end: CMTime(seconds: span.end, preferredTimescale: scale))
                let range = wanted.intersection(trackRange)
                if !range.isEmpty {
                    // Place by the span's own position so a track that
                    // starts late or ends early stays in sync.
                    let offset = range.start.seconds - span.start
                    try output.insertTimeRange(range, of: track,
                                               at: CMTime(seconds: outputStart + offset, preferredTimescale: scale))
                }
                outputStart += span.duration
            }
            if track.mediaType == .video {
                output.preferredTransform = try await track.load(.preferredTransform)
            }
        }
        return composition
    }
}
