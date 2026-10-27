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
    @Published private(set) var edits = EditList(sourceDuration: 0) {
        didSet { if edits != oldValue { refreshMarks() } }
    }
    /// Music and sound effects, saved to sound.json.
    @Published private(set) var sound = SoundPlan()
    /// Why some of the sound isn't playing, such as a moved music file.
    @Published private(set) var soundProblem: String?
    /// Playhead, in seconds of the original take.
    @Published private(set) var sourceTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var saveError: String?
    /// Shape of the video, so boxes drawn over the preview line up.
    @Published private(set) var videoSize: CGSize = .zero
    /// Mic loudness every 10 ms, for the waveform and finding silence.
    /// Nil until levels.json is read or measured.
    @Published private(set) var levels: LoudnessEnvelope? {
        didSet { if levels != oldValue { voiceLoudness = levels?.integratedLoudness() } }
    }
    /// The mic's integrated loudness, for the sound full mode's meter.
    @Published private(set) var voiceLoudness: Float?
    /// A stretch picked on the timeline, in seconds of the take. Delete
    /// cuts it.
    @Published var selection: TimeSpan?
    /// What you said or drew while watching, newest last.
    @Published var steerLog: [SteerEntry] = []
    /// Something said while holding Space that Ask should handle.
    @Published var pendingAsk: String?
    /// A tool a spoken edit asked for ("blur this" picks the pen).
    @Published var requestedTool: EditorTool?
    /// Mute and solo while listening in the sound full mode. Only the
    /// preview changes; exports always have every lane.
    @Published var laneMix = LaneMix() {
        didSet { if laneMix != oldValue { player.currentItem?.audioMix = previewAudioMix() } }
    }

    /// Words in time order and their spans, cached from the transcript.
    private(set) var words: [TranscriptWord] = []
    private(set) var wordSpans: [TimeSpan] = []
    /// How each word is drawn, kept in step with the edits so a long take
    /// isn't re-marked on every frame of playback.
    private(set) var wordMarks: [WordMark] = []

    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    /// Every cut id this editor has seen, so cuts written by someone else
    /// (auto-clean runs right after transcription) can be told apart
    /// from cuts the user removed here.
    private var knownCutIDs = Set<UUID>()
    /// Cuts merged in from outside while this editor was open. Undo and
    /// redo keep the ones that arrived after the step they go back to.
    private var outsideCutIDs = Set<UUID>()
    /// The preview as last built, so zooms and blurs can be redrawn
    /// without rebuilding it.
    private var preview: (composition: AVComposition, trackID: CMPersistentTrackID, renderSize: CGSize)?
    /// Which preview audio tracks belong to which lane, and the music and
    /// effects volume ramps, so mute and solo can be applied live.
    private var mixTracks: [MixLane: [CMPersistentTrackID]] = [:]
    private var soundParameters: [AVMutableAudioMixInputParameters] = []
    private var loadStarted = false

    init(take: Take) {
        self.take = take
        effects = EffectsModel(take: take, undoManager: undoManager)
    }

    // MARK: Loading

    /// Loads once, however many views (the full editor, the side panel)
    /// ask for it.
    func loadIfNeeded() async {
        guard !loadStarted else { return }
        loadStarted = true
        await load()
    }

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
            // Always the video's own length: auto-clean may have written
            // the shorter mic length, which would trim the end off.
            edits.sourceDuration = duration
            knownCutIDs = Set(edits.cuts.map(\.id))
            // A damaged sound.json shouldn't stop the take opening.
            sound = (try? SoundPlan.load(from: take.soundURL)) ?? SoundPlan()
        } catch {
            phase = .failed("Couldn't open this take: \(error.localizedDescription)")
            return
        }
        effects.onChange = { [weak self] in self?.refreshEffects() }
        effects.load(edits: edits)
        addTimeObserver()
        await rebuildPlayer()
        phase = .ready
        if let saved = try? LoudnessEnvelope.read(from: take.levelsURL) { levels = saved }
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
        outsideCutIDs.formUnion(new.map(\.id))
        return true
    }

    /// Picks up cuts an agent just wrote to edits.json, without waiting
    /// for the next two-second look.
    func pickUpOutsideCuts() {
        if mergeOutsideCuts() { scheduleRebuild() }
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
            refreshMarks()
            transcriptState = .ready
            // Ducking follows the words, so the preview needs them.
            if !sound.isEmpty { scheduleRebuild() }
            Task { await loadLevels() }
        } catch {
            transcriptState = .failed("The transcript couldn't be read: \(error.localizedDescription)")
        }
    }

    private func refreshMarks() {
        wordMarks = edits.marks(for: wordSpans)
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

    /// "Reject all": the words stay. Rejected cuts stay in the list so
    /// auto-clean doesn't suggest them again.
    func rejectAllProposed() {
        var next = edits
        for i in next.cuts.indices where next.cuts[i].state == .proposed {
            next.cuts[i].state = .rejected
        }
        apply(next, actionName: "Reject All")
    }

    /// Accepts or rejects one suggested cut. Does nothing once it's been
    /// decided, so a stale menu can't flip it back.
    func decide(_ id: UUID, accept: Bool) {
        guard edits.cuts.contains(where: { $0.id == id && $0.state == .proposed }) else { return }
        var next = edits
        next.setState(accept ? .accepted : .rejected, for: id)
        apply(next, actionName: accept ? "Accept Cut" : "Keep Words")
    }

    /// The suggested cut covering moment `t` of the take, if any.
    func proposedCut(at t: Double) -> Cut? {
        edits.cuts.first { $0.state == .proposed && $0.span.contains(t) }
    }

    var proposedCount: Int {
        edits.cuts.filter { $0.state == .proposed }.count
    }

    /// Internal so the Changes list (EditorModel+Changes) can switch a
    /// whole group of cuts as one undoable step.
    func apply(_ next: EditList, actionName: String) {
        let previous = edits
        let seen = outsideCutIDs
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.apply(model.keepingLateOutsideCuts(in: previous, seen: seen), actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        edits = next
        knownCutIDs.formUnion(next.cuts.map(\.id))
        save()
        scheduleRebuild()
    }

    /// `snapshot` plus any outside cuts that arrived after it was taken
    /// (not in `seen`), so undo doesn't throw away auto-clean's
    /// suggestions. One the user removed since isn't in `edits`, so it
    /// stays gone.
    private func keepingLateOutsideCuts(in snapshot: EditList, seen: Set<UUID>) -> EditList {
        var result = snapshot
        let ids = Set(snapshot.cuts.map(\.id))
        result.cuts += edits.cuts.filter {
            outsideCutIDs.contains($0.id) && !seen.contains($0.id) && !ids.contains($0.id)
        }
        return result
    }

    /// Swaps in `next` without an undo step: for suggestions only, which
    /// the user hasn't touched yet.
    private func replaceSuggestions(_ next: EditList) {
        guard next != edits else { return }
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

    /// Every sound change goes through here, like cuts through `apply`,
    /// so it can be undone. Pass `commit: false` while a slider or a
    /// drag is moving: the preview follows but nothing is saved or put
    /// on the undo stack until the gesture ends.
    func applySound(_ next: SoundPlan, actionName: String, commit: Bool = true, from start: SoundPlan? = nil) {
        guard commit else {
            sound = next
            scheduleRebuild()
            return
        }
        let previous = start ?? sound
        guard previous != next else {
            sound = next
            scheduleRebuild()
            return
        }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.applySound(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        sound = next
        do {
            try sound.write(to: take.soundURL)
            saveError = nil
        } catch {
            saveError = "Couldn't save the music and sound effects: \(error.localizedDescription)"
        }
        scheduleRebuild()
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
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
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
            let voiceTracks = composition.tracks(withMediaType: .audio).map(\.trackID)
            let timeline = ExportTimeline(keep: edits.keptSpans.map { $0.start..<$0.end },
                                          sourceDuration: edits.sourceDuration, frameRate: 0)
            let added = await SoundComposer.add(sound, timeline: timeline, words: wordSpans, to: composition)
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
            let soundTracks = added.tracks.map(\.trackID)
            mixTracks = [
                .voice: voiceTracks,
                .music: added.musicTrackID.map { [$0] } ?? [],
                .effects: soundTracks.filter { $0 != added.musicTrackID },
            ]
            soundParameters = added.parameters
            item.audioMix = previewAudioMix()
            soundProblem = added.problem
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

    /// The music and effects ramps, with muted lanes silenced.
    fileprivate func previewAudioMix() -> AVAudioMix? {
        func silent(_ id: CMPersistentTrackID) -> AVMutableAudioMixInputParameters {
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = id
            parameters.setVolume(0, at: .zero)
            return parameters
        }
        var inputs: [AVAudioMixInputParameters] = []
        for parameters in soundParameters {
            let lane: MixLane = (mixTracks[.music] ?? []).contains(parameters.trackID) ? .music : .effects
            inputs.append(laneMix.isAudible(lane) ? parameters : silent(parameters.trackID))
        }
        if !laneMix.isAudible(.voice) {
            inputs += (mixTracks[.voice] ?? []).map(silent)
        }
        guard !inputs.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs
        return mix
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
    static func make(from asset: AVAsset, keeping spans: [TimeSpan]) async throws -> AVMutableComposition {
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

// MARK: Levels, silence and the timeline

extension EditorModel {
    /// Reads levels.json, or measures the mic once and saves it. Takes
    /// cleaned before silence was checked against the mic get their
    /// undecided silence suggestions redone at the same time.
    func loadLevels() async {
        if levels != nil { return }
        if let saved = try? LoudnessEnvelope.read(from: take.levelsURL) {
            levels = saved
            return
        }
        guard let samples = try? await TakeAudio.read(take).samples else { return }
        let rate = TakeAudio.sampleRate
        let measured = await Task.detached(priority: .utility) {
            LoudnessEnvelope.measure(samples: samples, sampleRate: rate)
        }.value
        guard levels == nil else { return }
        levels = measured
        try? measured.write(to: take.levelsURL)
        guard !words.isEmpty else { return }
        let fresh = CleanupDetector().pauses(in: words, duration: edits.sourceDuration, loudness: measured)
        replaceSuggestions(SilenceCut.refreshSuggestions(edits, with: fresh))
    }

    /// "Cut the silence" from the Ask bar: every quiet stretch, cut now as
    /// one undo step.
    func cutSilence() async -> SilenceCut.Result {
        await loadLevels()
        let proposals = SilenceCut.proposals(words: words, duration: edits.sourceDuration, loudness: levels)
        let result = SilenceCut.apply(proposals, to: edits)
        if result.edits != edits { apply(result.edits, actionName: "Cut Silence") }
        return result
    }

    /// Length of the video if every dashed cut were accepted.
    var lengthIfAccepted: Double {
        var all = edits
        all.acceptAllProposed()
        return all.outputDuration
    }

    /// One frame (1/30 s) of the edited video forward or back.
    func stepFrames(_ frames: Int) {
        pause()
        skip(by: Double(frames) / 30)
    }

    func seekToStart() { seek(toSource: edits.keptSpans.first?.start ?? 0) }

    func seekToEnd() {
        seek(toSource: edits.sourceTime(forOutput: max(0, edits.outputDuration - 1.0 / 30)))
    }

    /// Delete on the timeline: cuts the picked stretch, or brings it back
    /// if all of it was already cut.
    func cutSelection() {
        guard let span = selection, span.duration > 0.01 else { return }
        var next = edits
        let removed = edits.removedSpans.contains { $0.start <= span.start + 1e-6 && span.end <= $0.end + 1e-6 }
        if removed {
            next.restore(span)
            apply(next, actionName: "Restore")
        } else {
            next.add(Cut(span: span, reason: Cut.Reason.word, state: .accepted))
            apply(next, actionName: "Cut")
        }
        selection = nil
        seek(toSource: span.start)
    }

    /// Where the kept video starts and ends, for the trim handles.
    var keptRange: TimeSpan {
        let kept = edits.keptSpans
        return TimeSpan(start: kept.first?.start ?? 0, end: kept.last?.end ?? edits.sourceDuration)
    }

    /// Drags the start trim handle to `t`: later cuts the opening,
    /// earlier brings it back.
    func trimStart(to t: Double) {
        let current = keptRange.start
        let target = min(max(0, t), keptRange.end - 0.5)
        guard abs(target - current) > 0.01 else { return }
        var next = edits
        if target < current {
            next.restore(TimeSpan(start: target, end: current))
        } else {
            next.add(Cut(span: TimeSpan(start: 0, end: target), reason: Cut.Reason.edge, state: .accepted))
        }
        apply(next, actionName: "Trim Start")
        seek(toSource: target)
    }

    /// Drags the end trim handle to `t`.
    func trimEnd(to t: Double) {
        let current = keptRange.end
        let target = max(min(edits.sourceDuration, t), keptRange.start + 0.5)
        guard abs(target - current) > 0.01 else { return }
        var next = edits
        if target > current {
            next.restore(TimeSpan(start: current, end: target))
        } else {
            next.add(Cut(span: TimeSpan(start: target, end: edits.sourceDuration), reason: Cut.Reason.edge, state: .accepted))
        }
        apply(next, actionName: "Trim End")
    }
}
