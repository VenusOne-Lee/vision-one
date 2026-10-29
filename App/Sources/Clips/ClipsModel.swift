import AppKit
import AVFoundation
import VisionOneKit

/// The clips of the take open in the editor. Reads and writes clips.json
/// next to edits.json; every change can be undone with the editor's
/// undo, and is saved straight away. The Clipper agent writes to the
/// same file, so clips it suggests show up here too.
@MainActor
final class ClipsModel: ObservableObject {
    enum ExportState: Equatable {
        case exporting(Double)
        case done(URL, Int64)
        case failed(String)
    }

    let take: Take
    private unowned let editor: EditorModel

    @Published private(set) var list = ClipList()
    @Published var selectedID: UUID?
    @Published private(set) var exports: [UUID: ExportState] = [:]
    /// Width over height of the recording.
    @Published private(set) var sourceAspect: Double = 16.0 / 9.0
    @Published var saveError: String?
    @Published private(set) var warnings: [UUID: String] = [:]
    @Published private(set) var queuedIDs: [UUID] = []
    @Published private(set) var cancelledIDs: Set<UUID> = []

    private(set) var events: EventLog?
    private var exportTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var framePlans: [ClipFormat: ReframePlan] = [:]
    private var watch: Task<Void, Never>?

    init(take: Take, editor: EditorModel) {
        self.take = take
        self.editor = editor
    }

    var undoManager: UndoManager { editor.undoManager }

    var selected: Clip? { selectedID.flatMap { list.clip(id: $0) } }

    var proposedCount: Int { list.clips.filter { $0.state == .proposed }.count }

    var canFind: Bool { editor.transcript.map { !$0.isEmpty } ?? false }

    var isExporting: Bool { !queuedIDs.isEmpty || exports.values.contains { if case .exporting = $0 { return true } else { return false } } }

    // MARK: Loading

    func load() async {
        do {
            list = try ClipList.load(from: take.clipsURL)
        } catch {
            saveError = "Couldn't read this take's clips: \(error.localizedDescription)"
        }
        if let data = try? Data(contentsOf: take.eventsURL) {
            events = try? JSONDecoder().decode(EventLog.self, from: data)
        }
        let asset = AVURLAsset(url: take.screenURL)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), size.height > 0 {
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let displayed = CGRect(origin: .zero, size: size).applying(transform)
            sourceAspect = Double(abs(displayed.width) / max(1, abs(displayed.height)))
            framePlans = [:]
            for format in ClipFormat.allCases {
                framePlans[format] = ClipFrame.reframe(format: format, framing: .follow,
                    sourceWidth: Int(abs(displayed.width)), sourceHeight: Int(abs(displayed.height)),
                    duration: editor.edits.sourceDuration, events: events)
            }
        }
        if selectedID == nil { selectedID = list.visible.first?.id }
        startWatching()
    }

    /// Picks up clips the Clipper agent writes while the editor is open.
    private func startWatching() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled,
                      let disk = try? ClipList.read(from: self.take.clipsURL) else { continue }
                let known = Set(self.list.clips.map(\.id))
                let new = disk.clips.filter { !known.contains($0.id) }
                if !new.isEmpty { self.list.clips += new }
            }
        }
    }

    func close() {
        watch?.cancel()
        playTask?.cancel()
    }

    // MARK: Suggesting

    /// Runs the on-device finder and adds what it finds as dashed
    /// suggestions. Clips already kept or turned down are left alone.
    func findClips() {
        guard let transcript = editor.transcript else { return }
        let finder = ClipFinder()
        let found = finder.clips(transcript: transcript, edits: editor.edits, existing: list.clips)
        var next = list
        let added = next.propose(found, sourceDuration: editor.edits.sourceDuration)
        guard !added.isEmpty else { return }
        apply(next, actionName: "Find Clips")
        selectedID = selectedID ?? added.first?.id
    }

    /// A new clip from the playhead, 30 seconds long, for making one by hand.
    func addAtPlayhead() {
        let start = editor.sourceTime
        let end = min(editor.edits.sourceDuration, start + 30)
        let words = editor.transcript?.words(from: start, to: end) ?? []
        var next = list
        guard let clip = next.add(Clip(title: ClipFinder.title(for: Array(words.prefix(12))),
                                       span: TimeSpan(start: start, end: end), state: .accepted),
                                  sourceDuration: editor.edits.sourceDuration) else { return }
        apply(next, actionName: "New Clip")
        selectedID = clip.id
    }

    // MARK: Changing clips

    func accept(_ id: UUID) { change(id, "Keep Clip") { $0.state = .accepted } }

    func reject(_ id: UUID) {
        change(id, "Turn Down Clip") { $0.state = .rejected }
        if selectedID == id { selectedID = list.visible.first?.id }
    }

    func acceptAll() {
        var next = list
        for clip in next.clips where clip.state == .proposed {
            next.setState(.accepted, for: clip.id)
        }
        apply(next, actionName: "Keep All Clips")
    }

    func rename(_ id: UUID, to title: String) {
        guard list.clip(id: id)?.title != title else { return }
        change(id, "Rename Clip") { $0.title = title }
    }

    func setFormat(_ format: ClipFormat, for id: UUID) { change(id, "Clip Format") { $0.format = format } }

    func setFramingMode(_ mode: ClipFraming.Mode, for id: UUID) {
        change(id, "Clip Framing") { clip in
            var framing = clip.framing
            if mode == .fixed, clip.framing.mode == .follow {
                framing = ClipFrame.resolved(clip, events: events)
            }
            framing.mode = mode
            clip.framing = framing
        }
    }

    /// Dragging the window on the video. Coalesced into one undo step
    /// per drag by the caller passing `final`.
    func moveWindow(_ id: UUID, centerX: Double, centerY: Double, final: Bool) {
        let framing = ClipFraming(mode: .fixed, centerX: centerX, centerY: centerY)
        if final {
            change(id, "Move Clip Window") { $0.framing = framing }
        } else {
            list.update(id) { $0.framing = framing }
        }
    }

    func trim(_ id: UUID, start: Double? = nil, end: Double? = nil, final: Bool = true) {
        var next = list
        next.trim(id, start: start, end: end, sourceDuration: editor.edits.sourceDuration)
        if final { apply(next, actionName: "Trim Clip") } else { list = next }
    }

    /// The window export will cut out of the screen for `clip`.
    func window(for clip: Clip) -> NormalisedRect {
        if clip.framing.mode == .follow, let plan = framePlans[clip.format] {
            return plan.crop(at: min(clip.end, max(clip.start, editor.sourceTime)))
        }
        return ClipFrame.rect(format: clip.format, sourceAspect: sourceAspect, framing: clip.framing)
    }

    func duration(of clip: Clip) -> Double { clip.duration(in: editor.edits) }

    private func change(_ id: UUID, _ actionName: String, _ body: (inout Clip) -> Void) {
        var next = list
        next.update(id, body)
        apply(next, actionName: actionName)
    }

    private func apply(_ next: ClipList, actionName: String) {
        let previous = list
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        list = next
        save()
    }

    private func save() {
        do {
            try list.write(to: take.clipsURL)
            saveError = nil
        } catch {
            saveError = "Couldn't save your clips: \(error.localizedDescription)"
        }
    }

    // MARK: Playing

    /// Plays the clip in the editor's preview and stops at its end.
    func play(_ clip: Clip) {
        selectedID = clip.id
        playTask?.cancel()
        editor.seek(toSource: clip.start)
        editor.play()
        let end = clip.end
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if !self.editor.isPlaying { return }
                if self.editor.sourceTime >= end {
                    self.editor.pause()
                    return
                }
            }
        }
    }

    var playhead: Double { editor.sourceTime }

    var sourceDuration: Double { editor.edits.sourceDuration }

    // MARK: Exporting

    /// Renders the clip to an MP4 next to the take: the clip's span with
    /// the editor's cuts left out, cut to its format and window.
    func export(_ clip: Clip) {
        guard !isExporting else { return }
        queuedIDs = [clip.id]
        exportTask = Task { await render(clip); queuedIDs = [] }
    }

    /// Exports every kept clip, one after another.
    func exportAccepted() {
        guard !isExporting else { return }
        let clips = list.accepted
        queuedIDs = clips.map(\.id)
        exportTask = Task {
            for clip in clips {
                guard !Task.isCancelled else {
                    cancelledIDs.formUnion(queuedIDs)
                    break
                }
                queuedIDs.removeAll { $0 == clip.id }
                await render(clip)
            }
            queuedIDs = []
        }
    }

    private func render(_ clip: Clip) async {
        let id = clip.id
        let keep = clip.keptSpans(in: editor.edits).map { $0.start..<$0.end }
        guard !keep.isEmpty else {
            exports[id] = .failed("Every part of this clip is cut.")
            return
        }
        var exporter = VideoExporter(take: take, keep: keep, preset: .hd1080)
        exporter.clip = (clip.format, clip.framing)
        exporter.captionRingHex = BrandStore.shared.kit.ring.hex
        exporter.ring = BrandStore.shared.kit.ring
        let look = AppliedTemplate.look(for: take)
        exporter.overlays = BrandStore.shared.overlays(look: look)
        exporter.cards = BrandStore.shared.cardMaker(look: look, templateFolder: AppliedTemplate.folder(for: take))
        cancelledIDs.remove(id)
        warnings[id] = nil
        exports[id] = .exporting(0)
        do {
            let output = try await exporter.run(to: take.clipURL(for: clip)) { progress in
                Task { @MainActor in
                    guard case .exporting = self.exports[id] else { return }
                    self.exports[id] = .exporting(progress)
                }
            }
            warnings[id] = CaptionExport.writeFiles(for: take, video: output.url, timeline: output.timeline, offset: output.videoStart)
            exports[id] = .done(output.url, output.bytes)
        } catch is CancellationError {
            exports[id] = nil
            cancelledIDs.insert(id)
        } catch {
            exports[id] = .failed(error.localizedDescription)
        }
    }

    func reveal(_ id: UUID) {
        if case let .done(url, _) = exports[id] {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }
}
