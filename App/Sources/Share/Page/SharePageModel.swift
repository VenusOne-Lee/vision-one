import AppKit
import SwiftUI
import VisionOneKit

/// One take's share page: its look, publishing it, and what viewers
/// sent back. Publishing makes a folder with no setup; with Cloudflare
/// connected it also goes up as a link with notes, reactions and
/// watch insights.
@MainActor
final class SharePageModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    let take: Take
    @Published var record: SharePageRecord { didSet { try? ShareLinkStore.save(record, for: take) } }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var inbox: ViewerInbox
    private var cloudflare: CloudflareConnection { .shared }

    init(take: Take) {
        self.take = take
        inbox = ViewerInbox.load(for: take)
        if let saved = ShareLinkStore.record(for: take) {
            record = saved
        } else {
            let kit = BrandStore.shared.kit
            var look = SharePageLook()
            look.ring = kit.ring.hex
            let title = SharePack.load(for: take)?.title ?? take.name
            let site = kit.site.trimmingCharacters(in: .whitespaces)
            let address = site.hasPrefix("http") ? site : "https://" + site
            let cta = URL(string: address).flatMap { url -> SharePageDocument.CallToAction? in
                guard !site.isEmpty, !kit.cta.isEmpty, url.host != nil else { return nil }
                return SharePageDocument.CallToAction(label: kit.cta, url: url)
            }
            record = SharePageRecord(slug: SharePageDocument.slug(for: title), look: look, callToAction: cta)
        }
    }

    var link: URL? { ShareLinkStore.link(for: take) }
    var isPublished: Bool { record.publishedAt != nil }
    var isBusy: Bool { if case .working = phase { return true } else { return false } }
    var hasExport: Bool { SharePagePublisher.video(for: take) != nil }
    var summary: ViewerSummary { ViewerSummary(events: inbox.events, duration: duration) }
    var curve: WatchCurve { WatchCurve(events: inbox.events, duration: duration) }
    var coachHint: ViewerCoachHint? { ViewerCoachHint.from(curve: curve, lines: lines) }

    private var document: SharePageDocument? {
        try? SharePageDocument.read(from: take.shareBundleFolder.appendingPathComponent("page.json"))
    }
    private var duration: Double { document?.duration ?? 0 }
    private var lines: [SharePageDocument.Line] { document?.lines ?? [] }

    func applyPreset(_ preset: SharePageLook.Preset) {
        var look = SharePageLook(preset)
        look.ring = record.look.ring
        look.transcript = record.look.transcript
        record.look = look
    }

    /// Builds the page and, with Cloudflare connected, puts it online.
    /// Without, shows the folder to put anywhere.
    func publish() async {
        let host = cloudflare.host
        let limit = host == nil ? nil : CloudflareShareHost.maxUploadBytes
        guard let video = SharePagePublisher.video(for: take, maxBytes: limit) else {
            phase = .failed(hasExport
                ? "Every export of this take is over 95 MB. Export 720p for the page."
                : "Export the video first. The page plays the export.")
            return
        }
        phase = .working("Building the page")
        do {
            let author = NSFullUserName()
            _ = try SharePagePublisher.build(take: take, record: record, author: author,
                                             api: host?.account.apiURL, video: video.url)
            var next = record
            next.videoFile = video.url.lastPathComponent
            if let host {
                phase = .working("Uploading to your Cloudflare")
                next.url = try await host.publish(bundle: take.shareBundleFolder, slug: record.slug)
                next.host = .cloudflare
            } else {
                next.host = .folder
                next.url = nil
                NSWorkspace.shared.activateFileViewerSelecting([take.shareBundleFolder.appendingPathComponent("index.html")])
            }
            next.publishedAt = Date()
            record = next
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func takeDown() async {
        guard let host = cloudflare.host, record.host == .cloudflare else { return }
        phase = .working("Taking the page down")
        do {
            try await host.takeDown(slug: record.slug)
            record.publishedAt = nil
            record.url = nil
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// New notes and watch events from the page. Each new note becomes
    /// an ask on the take's Desk task, with a plan for you to approve.
    func pull() async {
        guard let host = cloudflare.host, record.host == .cloudflare, isPublished else { return }
        do {
            var next = try await host.pull(slug: record.slug, into: inbox)
            let desk = AIServices.shared.desk
            let notes = next.unfiledNotes
            if !notes.isEmpty {
                let task = await desk.taskForRecording(take)
                for note in notes {
                    await desk.submit(note.editorAsk, to: task.id, mode: .planFirst)
                    next.markFiled(note.id)
                }
            }
            try? next.save(for: take)
            inbox = next
        } catch {
            // Quiet: the panel shows what it has and tries again later.
        }
    }

    func markDone(_ note: ViewerNote, _ done: Bool = true) {
        inbox.markDone(note.id, done)
        try? inbox.save(for: take)
    }

    func askEditor(_ text: String) {
        let take = self.take
        Task {
            let desk = AIServices.shared.desk
            let task = await desk.taskForRecording(take)
            await desk.submit(text, to: task.id, mode: .planFirst)
        }
    }

    func clearError() { phase = .idle }
}

/// The creator's Cloudflare account, connected once for every take.
@MainActor
final class CloudflareConnection: ObservableObject {
    static let shared = CloudflareConnection()

    @Published private(set) var account: CloudflareShareAccount? = CloudflareShareAccount.load()
    @Published private(set) var step: CloudflareShareSetup.Step?
    @Published private(set) var error: String?
    @Published private(set) var waitingForAddress = false

    private var secrets: AISecretStore { AIServices.shared.secrets }

    var host: CloudflareShareHost? {
        guard let account, let key = secrets.string(CloudflareSecretName.creatorKey) else { return nil }
        return CloudflareShareHost(account: account, creatorKey: key)
    }

    var isConnecting: Bool { step != nil }

    /// Sets up storage, the database and the share server with the
    /// pasted token. Running it again updates the server.
    func connect(token: String) async {
        error = nil
        let key = secrets.string(CloudflareSecretName.creatorKey) ?? CloudflareShareSetup.makeCreatorKey()
        do {
            try secrets.write(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8), for: CloudflareSecretName.apiToken)
            try secrets.write(Data(key.utf8), for: CloudflareSecretName.creatorKey)
            let setup = try CloudflareShareSetup(token: token)
            let made = try await setup.run(creatorKey: key) { step in
                Task { @MainActor in self.step = step }
            }
            try made.save()
            account = made
            step = .check
            try await waitUntilAnswering(made, key: key)
            step = nil
        } catch {
            step = nil
            self.error = error.localizedDescription
        }
    }

    /// A new workers.dev address can take a minute to switch on.
    private func waitUntilAnswering(_ account: CloudflareShareAccount, key: String) async throws {
        let host = CloudflareShareHost(account: account, creatorKey: key)
        for attempt in 0..<12 {
            do {
                try await host.checkHealth()
                waitingForAddress = false
                return
            } catch CloudflareShareError.notReachableYet where attempt < 11 {
                waitingForAddress = true
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Forgets the account on this Mac. Pages already up stay up.
    func disconnect() {
        try? FileManager.default.removeItem(at: CloudflareShareAccount.standardURL)
        secrets.delete(CloudflareSecretName.apiToken)
        account = nil
    }
}
