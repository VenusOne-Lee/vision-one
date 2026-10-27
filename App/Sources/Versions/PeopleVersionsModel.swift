import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VisionOneKit

/// One demo, many versions: a copy of the take for each person on a
/// list, with their name on the title card. Everything happens on this
/// Mac; nothing is sent anywhere. See docs/VERSIONS.md.
@MainActor
final class PeopleVersionsModel: ObservableObject {
    enum RowState: Equatable {
        case ready
        case making(Double)
        case made(URL)
        case failed(String)
    }

    enum Phase: Equatable {
        case editing
        case making(done: Int, total: Int)
        case finished(made: Int, failed: Int)
    }

    let take: Take

    @Published var pasted = "" {
        didSet { if pasted != oldValue { reparse() } }
    }
    @Published var settings: VersionSettings {
        didSet {
            try? take.saveVersionSettings(settings)
            replan()
        }
    }
    @Published var preset: ExportPreset = .hd1080
    @Published private(set) var list = RecipientList()
    @Published private(set) var versions: [PlannedVersion] = []
    @Published private(set) var rows: [Int: RowState] = [:]
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var videoSeconds: Double = 0
    /// The take's translated caption languages, for the language column.
    @Published private(set) var captionLanguages: [SALanguage] = []

    private var task: Task<Void, Never>?
    private var jobID: UUID?

    init(take: Take) {
        self.take = take
        settings = take.loadVersionSettings()
        captionLanguages = take.captionLanguages()
        let spoken = (try? Transcript.read(from: take.transcriptURL))?.duration ?? 0
        if let edits = try? EditList.load(from: take.editsURL, sourceDuration: spoken) {
            videoSeconds = edits.outputDuration
        }
    }

    var folder: URL { VersionPlanner.folder(for: take) }
    var isMaking: Bool { if case .making = phase { return true } else { return false } }

    /// "About 25 min on this Mac".
    var estimate: String {
        let seconds = VersionPlanner.estimatedSeconds(count: versions.count, videoSeconds: max(videoSeconds, 10),
                                                      cardSeconds: settings.titleCard ? settings.clampedDuration : 0)
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes <= 1 ? "About a minute on this Mac" : "About \(minutes) min on this Mac"
    }

    // MARK: List

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a list of people"
        panel.message = "A CSV or text file with a name on each line. Company and email columns are picked up."
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .utf8PlainText]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        // Excel on Windows still saves CSVs as Latin-1.
        if let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) {
            pasted = text
        }
    }

    private func reparse() {
        list = RecipientList.parse(pasted)
        replan()
    }

    private func replan() {
        versions = VersionPlanner.plan(list, settings: settings, product: BrandStore.shared.kit.name,
                                       available: captionLanguages)
        guard !isMaking else { return }
        rows = [:]
        if case .finished = phase { phase = .editing }
    }

    // MARK: Making

    func make() {
        guard !versions.isEmpty, !isMaking else { return }
        let versions = versions
        let take = take
        let settings = settings
        let preset = preset
        let folder = folder
        rows = Dictionary(uniqueKeysWithValues: versions.map { ($0.id, RowState.ready) })
        phase = .making(done: 0, total: versions.count)

        let board = AIServices.shared.jobs
        let job = AgentJob(agent: .producer, title: "Versions for \(versions.count) \(versions.count == 1 ? "person" : "people")",
                           take: take, ask: nil,
                           steps: ["Read the list", "Title card for each person", "Make \(versions.count) videos",
                                   "Write versions.csv for your mail merge"])
        jobID = job.id
        task = Task {
            await board.add(job)
            await board.step(job.id, 2)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var made = 0
            var failed = 0
            var status: [Int: String] = [:]
            for version in versions {
                if Task.isCancelled { break }
                rows[version.id] = .making(0)
                do {
                    let url = try await Self.export(version, take: take, settings: settings, preset: preset, folder: folder) { p in
                        Task { @MainActor in
                            if case .making = self.rows[version.id] { self.rows[version.id] = .making(p) }
                        }
                    }
                    rows[version.id] = .made(url)
                    status[version.id] = "made"
                    made += 1
                } catch is CancellationError {
                    rows[version.id] = .ready
                    break
                } catch {
                    rows[version.id] = .failed(error.localizedDescription)
                    status[version.id] = "failed: \(error.localizedDescription)"
                    failed += 1
                }
                phase = .making(done: made + failed, total: versions.count)
            }
            await board.step(job.id, 3)
            let csv = VersionPlanner.csv(versions, folder: folder, status: status)
            try? csv.write(to: folder.appendingPathComponent("versions.csv"), atomically: true, encoding: .utf8)
            phase = .finished(made: made, failed: failed)
            if Task.isCancelled {
                await board.cancel(job.id)
            } else if made == 0, failed > 0 {
                let reason = rows.values.compactMap { state -> String? in
                    if case let .failed(message) = state { return message }
                    return nil
                }.first ?? ""
                await board.fail(job.id, "None of the versions could be made. \(reason)")
            } else {
                await board.finish(job.id, receipt: AgentReceipt.versions(made: made, failed: failed), changes: [])
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reveal() {
        let csv = folder.appendingPathComponent("versions.csv")
        if FileManager.default.fileExists(atPath: csv.path) {
            NSWorkspace.shared.activateFileViewerSelecting([csv])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    /// One person's copy, through the same exporter as Export, with their
    /// title card in place of the brand intro.
    private static func export(_ version: PlannedVersion, take: Take, settings: VersionSettings, preset: ExportPreset,
                               folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let store = BrandStore.shared
        var brand = store.kit
        if settings.titleCard {
            brand.intro = BrandCard(enabled: true, duration: settings.clampedDuration)
        }
        var cards = CardMaker(brand: brand, brandFolder: store.folder, look: nil, templateFolder: nil)
        if settings.titleCard {
            cards.personal = (version.headline, version.subline)
        }
        var exporter = VideoExporter(take: take, keep: nil, preset: preset, overlays: store.overlays(),
                                     captionRingHex: brand.ring.hex, cards: cards)
        exporter.ring = brand.ring
        exporter.captionLanguage = version.captionLanguage
        let url = folder.appendingPathComponent(version.fileName)
        _ = try await exporter.run(to: url, progress: progress)
        return url
    }
}

/// The Versions window, opened from the editor.
@MainActor
final class PeopleVersionsWindowController {
    static let shared = PeopleVersionsWindowController()
    private var window: NSWindow?
    private var model: PeopleVersionsModel?

    func show(for take: Take) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 620, height: 460)
            window.setFrameAutosaveName("VisionOneVersions")
            window.center()
            self.window = window
        }
        // Keep a running batch's window; otherwise follow the take.
        if model?.take.folder != take.folder, model?.isMaking != true {
            let model = PeopleVersionsModel(take: take)
            self.model = model
            window?.contentViewController = NSHostingController(rootView: PeopleVersionsView(model: model))
        }
        window?.title = "Versions · \(take.name.replacingOccurrences(of: "Vision One ", with: ""))"
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
