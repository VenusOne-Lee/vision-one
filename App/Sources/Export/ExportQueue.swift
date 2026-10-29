import AppKit
import Combine
import VisionOneKit

/// Exports several presets of one take, one after another.
/// `ExportController` runs one export at a time, so the next preset only
/// starts once the controller has left `.exporting`. Progress for each
/// preset comes from the controller's phase, kept in an `ExportBatch`.
/// There's one for the app, so closing the export sheet doesn't stop
/// the batch, and opening it again shows where it's got to.
@MainActor
final class ExportQueue: ObservableObject {
    static let shared = ExportQueue()

    @Published private(set) var batch: ExportBatch?
    /// The take the batch is for.
    private(set) var take: Take?
    /// When the batch started, for the time-left guess.
    private(set) var startedAt: Date?

    private let controller: ExportController
    private var keep: [Range<Double>]?
    private var watching: AnyCancellable?

    private init() {
        let controller = ExportController.shared
        self.controller = controller
        // Phases arrive on the next turn of the main queue, after the
        // controller has finished setting them, so starting the next
        // export from here sees the controller's real state.
        watching = controller.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                MainActor.assumeIsolated { self?.follow(phase) }
            }
    }

    var isRunning: Bool { batch?.isRunning ?? false }

    /// Starts exporting `presets` of `take`. `keep` overrides the kept
    /// spans; nil uses the take's edits.json, as the Export menu does.
    func export(_ take: Take, presets: [ExportPreset], keep: [Range<Double>]?) {
        guard !isRunning, !presets.isEmpty else { return }
        self.take = take
        self.keep = keep
        startedAt = Date()
        batch = ExportBatch(presets)
        startNext()
    }

    /// Stops the running export and everything after it.
    func cancel() {
        guard isRunning else { return }
        batch?.cancel()
        if batch?.current != nil { controller.cancel() }
    }

    /// Forgets a finished batch, so the formats can be picked again.
    func reset() {
        guard !isRunning else { return }
        batch = nil
        startedAt = nil
    }

    /// The batch, when it's for `take`.
    func batch(for take: Take) -> ExportBatch? {
        self.take?.folder == take.folder ? batch : nil
    }

    func revealExports() {
        guard let urls = batch?.exported, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func follow(_ phase: ExportPhase) {
        guard batch != nil else { return }
        batch?.apply(phase)
        startNext()
    }

    private func startNext() {
        guard let take, let preset = batch?.next else { return }
        // Something else is exporting (the menu bar panel, say); wait for
        // it to finish and go then.
        guard !controller.phase.isBusy else { return }

        batch?.start(preset)
        // The same call as the Export menu: captions are built inside the
        // export, from the timeline it renders; subtitle files follow once
        // the video is done.
        let brand = BrandStore.shared
        let look = AppliedTemplate.look(for: take)
        controller.export(take, preset: preset, keep: keep,
                          overlays: brand.overlays(look: look),
                          captionRingHex: brand.kit.ring.hex,
                          cards: brand.cardMaker(look: look, templateFolder: AppliedTemplate.folder(for: take)))

        guard case let .exporting(running, _) = controller.phase, running == preset else {
            batch?.fail(preset, message: "Couldn't start the \(preset.title) export.")
            startNext()
            return
        }
    }
}
