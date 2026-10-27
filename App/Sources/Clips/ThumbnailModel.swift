import AppKit
import VisionOneKit

/// The thumbnail of the take open in the editor: five suggested frames,
/// the design the user is shaping (title, positions, sizes), a live
/// preview, and saving the images into the take's thumbnails folder.
@MainActor
final class ThumbnailModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case finding
        case saving
        case saved([URL])
        case failed(String)
    }

    struct Candidate: Identifiable {
        let metrics: ThumbnailPicker.Metrics
        let image: CGImage
        var id: Double { metrics.time }
    }

    let take: Take
    private unowned let editor: EditorModel
    private unowned let clips: ClipsModel
    private let renderer: ThumbnailRenderer

    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var design: ThumbnailDesign?
    @Published private(set) var preview: CGImage?
    @Published private(set) var layout: ThumbnailRenderer.Layout?
    /// The size shown in the editor; saving writes every chosen size.
    @Published var previewSize: ThumbnailSize = .youtube
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasCamera = false

    private var frame: CGImage?
    private var camera: CGImage?
    private var frameTime: Double?
    private var renderTask: Task<Void, Never>?

    init(take: Take, editor: EditorModel, clips: ClipsModel) {
        self.take = take
        self.editor = editor
        self.clips = clips
        self.renderer = ThumbnailRenderer(take: take)
    }

    // MARK: Loading

    private var loaded = false

    /// Loads the first time the Thumbnail tab opens; grabbing frames
    /// takes a moment, so it isn't done for every take opened.
    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await load()
    }

    /// Opens the saved design, or suggests one from the best frame.
    func load() async {
        hasCamera = FileManager.default.fileExists(atPath: take.cameraURL.path)
        design = try? ThumbnailDesign.read(from: take.thumbnailDesignURL)
        await findFrames()
    }

    func findFrames() async {
        guard editor.edits.outputDuration > 0 else { return }
        phase = .finding
        let events = clips.events
        let found = await renderer.candidates(edits: editor.edits, events: events, picker: ThumbnailPicker())
        candidates = found.map { Candidate(metrics: $0.0, image: $0.1) }
        phase = .idle
        if design == nil, let best = candidates.first {
            design = ThumbnailDesign(
                time: best.metrics.time,
                title: ThumbnailTitle.suggested(transcript: editor.transcript, clips: clips.list, edits: editor.edits),
                showFace: hasCamera)
        }
        refresh()
    }

    // MARK: Changing the design

    func choose(_ time: Double) { change { $0.time = time } }

    func setTitle(_ title: String) { change { $0.title = title } }

    func setTitleWidth(_ width: Double) { change { $0.titleWidth = min(max(width, 0.2), 0.95) } }

    func setFaceSize(_ size: Double) { change { $0.faceSize = min(max(size, 0.15), 0.8) } }

    func setShowFace(_ show: Bool) { change { $0.showFace = show } }

    func moveTitle(x: Double, y: Double) { change { $0.moveTitle(x: x, y: y) } }

    func moveFace(x: Double, y: Double) { change { $0.moveFace(x: x, y: y) } }

    func toggle(_ size: ThumbnailSize) {
        change { design in
            if let i = design.sizes.firstIndex(of: size) {
                if design.sizes.count > 1 { design.sizes.remove(at: i) }
            } else {
                design.sizes.append(size)
            }
        }
        if let sizes = design?.sizes, !sizes.contains(previewSize), let first = sizes.first {
            previewSize = first
            refresh()
        }
    }

    private func change(_ body: (inout ThumbnailDesign) -> Void) {
        guard var next = design else { return }
        body(&next)
        guard next != design else { return }
        design = next
        try? next.write(to: take.thumbnailDesignURL)
        if case .saved = phase { phase = .idle }
        refresh()
    }

    /// Redraws the preview, grabbing a new frame only when the time moved.
    func refresh() {
        guard let design else { return }
        renderTask?.cancel()
        let size = previewSize
        renderTask = Task {
            if frameTime != design.time || frame == nil {
                frame = try? await renderer.screenFrame(at: design.time, maxSize: 1920)
                camera = await renderer.cameraFrame(at: design.time, maxSize: 720)
                frameTime = design.time
            }
            guard !Task.isCancelled, let frame else { return }
            if let drawn = ThumbnailRenderer.compose(frame: frame, camera: camera, design: design,
                                                     size: size, scale: 0.5) {
                preview = drawn.0
                layout = drawn.1
            }
        }
    }

    // MARK: Saving

    /// Draws every chosen size at full resolution into thumbnails/.
    func save() {
        guard let design, phase != .saving else { return }
        phase = .saving
        Task {
            do {
                let frame = try await renderer.screenFrame(at: design.time)
                let camera = await renderer.cameraFrame(at: design.time)
                var urls: [URL] = []
                for size in design.sizes {
                    guard let drawn = ThumbnailRenderer.compose(frame: frame, camera: camera, design: design, size: size) else {
                        throw ThumbnailRenderer.Failure.noFrame
                    }
                    let url = take.thumbnailURL(for: size)
                    try ThumbnailRenderer.write(drawn.0, size: size, to: url)
                    urls.append(url)
                }
                phase = .saved(urls)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reveal() {
        if case let .saved(urls) = phase { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}
