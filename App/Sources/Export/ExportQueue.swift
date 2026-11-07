import AppKit
import Combine
import VisionOneKit

/// Serial multi-take delivery. Each take keeps its batch and results while
/// another take runs. Jobs read the take's saved settings when they start.
@MainActor
final class ExportQueue: ObservableObject {
    static let shared = ExportQueue(controller: .shared, remembers: true)

    struct Request: Identifiable {
        let id = UUID()
        let take: Take
        let presets: [ExportPreset]
        let keep: [Range<Double>]?
        var initialBatch: ExportBatch? = nil
    }
    @Published private(set) var batch: ExportBatch?
    @Published private(set) var waiting: [Request] = []
    @Published private(set) var finished: [URL: ExportBatch] = [:]
    @Published private(set) var warnings: [URL: [String]] = [:]
    private(set) var take: Take?
    private(set) var startedAt: Date?
    private let controller: ExportController
    private var keep: [Range<Double>]?
    private var watching: AnyCancellable?
    private var requests: [URL: Request] = [:]
    /// Only the app's own queue keeps unfinished exports across a quit;
    /// test and verification queues never touch the saved list.
    private let remembers: Bool
    private var lastSaved = PendingExports()

    init(controller: ExportController, remembers: Bool = false) {
        self.controller = controller
        self.remembers = remembers
        watching = controller.$phase.receive(on: DispatchQueue.main).sink { [weak self] phase in
            MainActor.assumeIsolated {
                self?.follow(phase)
                self?.remember()
            }
        }
    }

    /// Picks up exports a quit left unfinished, for takes still on disk.
    func resumeUnfinished() {
        guard remembers else { return }
        let pending = PendingExports.load()
        // What's on disk now, so the next save replaces it even when none
        // of it could be picked up.
        lastSaved = pending
        for entry in pending.entries {
            let take = Take(folder: entry.takeFolder)
            guard FileManager.default.fileExists(atPath: take.screenURL.path) else { continue }
            export(take, presets: entry.presets, keep: entry.keep)
        }
        remember()
    }

    /// Saves what's still to export, only when that list changed.
    private func remember() {
        guard remembers else { return }
        var entries: [PendingExports.Entry] = []
        if let take, let batch, batch.isRunning {
            entries.append(.init(takeFolder: take.folder, presets: batch.unfinished, keep: keep))
        }
        for request in waiting {
            entries.append(.init(takeFolder: request.take.folder,
                                 presets: request.initialBatch?.unfinished ?? ExportBatch(request.presets).unfinished,
                                 keep: request.keep))
        }
        let pending = PendingExports(entries: entries).cleaned
        guard pending != lastSaved else { return }
        lastSaved = pending
        try? pending.save()
    }
    var isRunning: Bool { batch?.isRunning == true || !waiting.isEmpty }

    func export(_ take: Take, presets: [ExportPreset], keep: [Range<Double>]?) {
        guard !presets.isEmpty else { return }
        guard batch(for: take)?.isRunning != true else { return }
        let request = Request(take: take, presets: presets, keep: keep)
        requests[take.folder] = request
        finished[take.folder] = nil
        warnings[take.folder] = []
        if batch?.isRunning == true {
            waiting.append(request)
        } else { begin(request) }
        remember()
    }

    func cancel(_ target: Take? = nil) {
        let target = target ?? take
        guard let target else { return }
        if let index = waiting.firstIndex(where: { $0.take.folder == target.folder }) {
            let request = waiting.remove(at: index)
            var cancelled = request.initialBatch ?? ExportBatch(request.presets)
            cancelled.cancel()
            finished[target.folder] = cancelled
            remember()
            return
        }
        guard target.folder == take?.folder, batch?.isRunning == true else { return }
        batch?.cancel()
        if batch?.current != nil { controller.cancel() }
        else { startNext() }
        remember()
    }

    func retry(_ take: Take) {
        guard var resumed = batch(for: take), !resumed.isRunning else { return }
        resumed.retryUnfinished()
        guard resumed.isRunning else { return }
        let request = Request(take: take, presets: resumed.presets, keep: requests[take.folder]?.keep, initialBatch: resumed)
        requests[take.folder] = request
        if batch?.isRunning == true { waiting.append(request) }
        else { begin(request) }
        remember()
    }

    func reset(_ target: Take? = nil) {
        guard let target = target ?? take, batch(for: target)?.isRunning != true else { return }
        finished[target.folder] = nil
        warnings[target.folder] = nil
        requests[target.folder] = nil
        if take?.folder == target.folder { batch = nil; startedAt = nil }
    }

    func batch(for take: Take) -> ExportBatch? {
        if self.take?.folder == take.folder { return batch }
        if let request = waiting.first(where: { $0.take.folder == take.folder }) { return request.initialBatch ?? ExportBatch(request.presets) }
        return finished[take.folder]
    }
    func position(of take: Take) -> Int? {
        waiting.firstIndex(where: { $0.take.folder == take.folder }).map { $0 + 1 }
    }
    func revealExports() {
        guard let urls = batch?.exported, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
    private func begin(_ request: Request) {
        take = request.take
        keep = request.keep
        startedAt = Date()
        batch = request.initialBatch ?? ExportBatch(request.presets)
        startNext()
    }
    private func follow(_ phase: ExportPhase) {
        guard batch?.isRunning == true else { return }
        if case let .done(preset, _, _) = phase, batch?.current == preset, let take, let warning = controller.warning {
            warnings[take.folder, default: []].append(warning)
        }
        batch?.apply(phase)
        startNext()
    }
    private func startNext() {
        guard let take else { return }
        guard let preset = batch?.next else {
            if let batch, !batch.isRunning {
                finished[take.folder] = batch
                if !waiting.isEmpty { begin(waiting.removeFirst()) }
            }
            return
        }
        guard !controller.phase.isBusy else { return }
        batch?.start(preset)
        let brand = BrandStore.shared
        let look = AppliedTemplate.look(for: take)
        controller.export(take, preset: preset, keep: keep,
                          overlays: brand.overlays(look: look), captionRingHex: brand.kit.ring.hex,
                          cards: brand.cardMaker(look: look, templateFolder: AppliedTemplate.folder(for: take)))
        guard case let .exporting(running, _) = controller.phase, running == preset else {
            batch?.fail(preset, message: "Couldn't start the \(preset.title) export.")
            startNext()
            return
        }
    }
}
