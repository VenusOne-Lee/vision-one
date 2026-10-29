import AppKit
import SwiftUI
import VisionOneKit

/// Where a take's share link comes from. Nil until the share page is
/// published, and the link row stays hidden until then.
@MainActor
enum ShareLinks {
    static var lookup: (Take) -> URL? = { ShareLinkStore.link(for: $0) }
    static func link(for take: Take) -> URL? { lookup(take) }
}

/// The posts you told Vision One not to ask about again, saved for the
/// MCP server too. See `PostRules`.
@MainActor
final class PostRulesStore: ObservableObject {
    static let shared = PostRulesStore()
    @Published private(set) var rules = PostRules.load()

    func allows(_ destination: String) -> Bool {
        rules.allows(scope: scope, destination: destination)
    }

    func allow(_ destination: String) {
        rules.allow(scope: scope, destination: destination)
        try? rules.write()
    }

    func forget(_ destination: String) {
        rules.forget(scope: scope, destination: destination)
        try? rules.write()
    }

    /// The product the posts are for: the brand kit's name.
    var scope: String { BrandStore.shared.kit.name }
}

/// The Post tab of the task panel, and the lower half of Ready to share:
/// the Version One draft first, then WhatsApp, LinkedIn, X and YouTube,
/// then the link. Every post is a dashed draft until you approve it on
/// a numbered card; approving copies the words, shows the right file
/// and opens the place to post. Nothing posts by itself. Fits any
/// panel width from about 280 pt.
struct PostPanel: View {
    let take: Take
    var onNetworkMount: ((ShareTarget, PostDraftControl) -> Void)? = nil

    var body: some View {
        PostPanelContent(take: take, onNetworkMount: onNetworkMount)
            .id(take.folder)
    }
}

private struct PostPanelContent: View {
    let take: Take

    @StateObject private var agents: AgentsModel
    @ObservedObject private var queue = ExportQueue.shared
    @ObservedObject private var rules = PostRulesStore.shared
    @ObservedObject private var transcriber = Transcriber.shared

    let onNetworkMount: ((ShareTarget, PostDraftControl) -> Void)?

    init(take: Take, onNetworkMount: ((ShareTarget, PostDraftControl) -> Void)? = nil) {
        self.take = take
        self.onNetworkMount = onNetworkMount
        _agents = StateObject(wrappedValue: AgentsModel(take: take))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                if agents.share == nil {
                    draftFirst
                } else {
                    VersionOneCard(take: take, agents: agents, rules: rules)
                }
                PanelLabel("Socials")
                VStack(spacing: Theme.Space.sm) {
                    ForEach(ShareTarget.allCases) { target in
                        NetworkRow(take: take, target: target, agents: agents, queue: queue, rules: rules, onMount: onNetworkMount)
                    }
                }
                if let link = ShareLinks.link(for: take) {
                    LinkRow(link: link)
                }
                SharePageSection(take: take)
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.canvas)
    }

    private var hasTranscript: Bool {
        FileManager.default.fileExists(atPath: take.transcriptURL.path)
    }

    private var canDraftWithSharer: Bool { PostCopy.canDraft(for: take) }

    /// Before the Sharer has written anything: one button, or a wait for
    /// the transcript it reads.
    private var draftFirst: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(canDraftWithSharer ? "Nothing drafted yet" : "Write your own post copy")
                .textStyle(.headline)
                .foregroundStyle(Theme.text)
            Text(canDraftWithSharer
                 ? "The Sharer writes a title, chapters, a Version One launch and a post for each network from what you said."
                 : "Automatic drafts need at least \(SharerAgent.minimumWords) kept words. Your video is ready to edit and export. Expand a network below to write your own copy.")
                .textStyle(.body)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            RunStatus(run: agents.sharerRun)
            Button("Draft with Sharer") { if canDraftWithSharer { agents.runSharer(launch: true) } }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(!canDraftWithSharer || agents.sharerRun.isRunning)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .statusOutline(.proposed, cornerRadius: Theme.Radius.lg)
    }
}

extension AgentsModel.Run {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Version One

/// "Version One · draft": the launch the Sharer wrote, with Approve and
/// post and Edit. Approving asks on the numbered card, unless you said
/// not to ask again for this product's posts.
private struct VersionOneCard: View {
    let take: Take
    @ObservedObject var agents: AgentsModel
    @ObservedObject var rules: PostRulesStore

    private static let host = "versionone.co.za"

    @State private var editing = false
    @StateObject private var draftCopy: PostDraftControl

    init(take: Take, agents: AgentsModel, rules: PostRulesStore) {
        self.take = take
        self.agents = agents
        self.rules = rules
        _draftCopy = StateObject(wrappedValue: PostDraftControl(take: take, destination: "versionone"))
    }

    private var draft: String { agents.share?.launch?.postText ?? "" }
    private var words: String { draftCopy.manualText ?? draft }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("VERSION ONE · \(draftCopy.posted ? "COPIED" : "DRAFT")")
                    .textStyle(.caption)
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 0)
                if rules.allows(Self.host) {
                    Button("Ask every time") { rules.forget(Self.host) }
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                        .help("You said not to ask again for \(rules.scope) posts. Ask again from now on.")
                }
            }
            if let launch = agents.share?.launch {
                if editing {
                    TextEditor(text: Binding(get: { words }, set: { draftCopy.edit($0) }))
                        .textStyle(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 96, maxHeight: 180)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(Theme.lineStrong, lineWidth: Theme.Stroke.hairline))
                        .disabled(!draftCopy.loaded)
                } else {
                    Text(draftCopy.manualText == nil ? launch.name : (words.split(separator: "\n").first.map(String.init) ?? "Post copy is empty"))
                        .textStyle(.headline)
                        .foregroundStyle(Theme.text)
                    Text(draftCopy.manualText == nil ? launch.oneLine : words.split(separator: "\n").dropFirst().joined(separator: "\n"))
                        .textStyle(.body)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if draftCopy.asking {
                    ApprovalCard(agent: "Sharer", question: PostApprovalText.question(to: "Version One"),
                                 quote: words, options: PostApprovalText.options(scope: rules.scope),
                                 onAnswer: answer, onLater: { draftCopy.asking = false })
                } else if draftCopy.posted {
                    Text("Copied. Version One is open in your browser: paste it into your launch and post.")
                        .textStyle(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Theme.Space.sm) {
                        Button("Copy again") { copy(words) }
                            .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                        Button("Open Version One") { open() }
                            .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                    }
                } else {
                    HStack(spacing: Theme.Space.sm) {
                        Button("Copy and open Version One") { approve() }
                            .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                            .disabled(words.isEmpty || !draftCopy.loaded)
                        Button(editing ? "Done" : "Edit") {
                            if !editing, draftCopy.manualText == nil { draftCopy.edit(draft) }
                            editing.toggle()
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    }
                }
            } else {
                Text("The Sharer's draft has no Version One launch yet.")
                    .textStyle(.body)
                    .foregroundStyle(Theme.textMuted)
                Button("Write a launch") { if PostCopy.canDraft(for: take) { agents.runSharer(launch: true) } }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    .disabled(!PostCopy.canDraft(for: take) || agents.sharerRun.isRunning)
            }
            if let problem = draftCopy.problem {
                Text(problem).textStyle(.caption).foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                Button(draftCopy.loaded ? "Retry saving copy" : "Retry loading copy") {
                    if draftCopy.loaded { draftCopy.save() } else { draftCopy.reload() }
                }.buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            }
            RunStatus(run: agents.sharerRun)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .statusOutline(draftCopy.posted ? .accepted : .proposed, cornerRadius: Theme.Radius.lg)
        .onChange(of: agents.share) { _, _ in
            // Generated copy never discards an explicit manual edit.
            draftCopy.asking = false
            draftCopy.posted = false
        }
    }

    private func approve() {
        editing = false
        if rules.allows(Self.host) { post() } else { draftCopy.asking = true }
    }

    private func answer(_ answer: ApprovalAnswer) {
        draftCopy.asking = false
        switch answer {
        case .yes: post()
        case .yesAlways:
            rules.allow(Self.host)
            post()
        case let .no(feedback):
            agents.runSharer(note: feedback.isEmpty ? nil : feedback, launch: true)
        }
    }

    /// Version One has no posting door for apps yet, so the launch goes on
    /// the clipboard and the site opens. The Vision One MCP server will
    /// post it straight through Version One's share_launch.
    private func post() {
        let words = words
        Task {
            await AIServices.shared.gate.approvedInPlace(
                SharerAgent.postRequest(words, to: Self.host, network: "version one"))
        }
        copy(words)
        open()
        draftCopy.posted = true
    }

    private func copy(_ words: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words, forType: .string)
    }

    private func open() {
        NSWorkspace.shared.open(URL(string: "https://\(Self.host)")!)
    }
}

// MARK: - Networks

/// One network: what the Sharer wrote for it, the file it would take, and
/// Post. With no file yet it exports the one that suits the network
/// first (Vertical for WhatsApp, Square for LinkedIn, 1080p for X and
/// YouTube).
private struct NetworkRow: View {
    let take: Take
    let target: ShareTarget
    @ObservedObject var agents: AgentsModel
    @ObservedObject var queue: ExportQueue
    @ObservedObject var rules: PostRulesStore

    @StateObject private var copy: PostDraftControl
    let onMount: ((ShareTarget, PostDraftControl) -> Void)?

    init(take: Take, target: ShareTarget, agents: AgentsModel, queue: ExportQueue,
         rules: PostRulesStore, onMount: ((ShareTarget, PostDraftControl) -> Void)? = nil) {
        self.take = take
        self.target = target
        self.agents = agents
        self.queue = queue
        self.rules = rules
        self.onMount = onMount
        _copy = StateObject(wrappedValue: PostDraftControl(take: take, destination: target.network))
    }

    private var files: [ExportPreset: URL] {
        var files = queue.batch(for: take)?.files ?? [:]
        // Exports from earlier sessions, saved next to the take.
        for preset in target.preferred where files[preset] == nil {
            let url = take.exportURL(for: preset)
            if FileManager.default.fileExists(atPath: url.path) { files[preset] = url }
        }
        return files
    }

    private var file: (preset: ExportPreset, url: URL)? { target.file(from: files) }
    private var draft: String { target.text(in: agents.share) ?? "" }
    private var words: String { copy.manualText ?? draft }

    private var exporting: Double? {
        guard let batch = queue.batch(for: take), batch.isRunning,
              let preset = target.preferred.first, batch.presets.contains(preset) else { return nil }
        return ExportProgress.overall(batch) { _ in 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button {
                withAnimation(Theme.Motion.enter) { copy.open.toggle() }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: FinishedPanel.icon(target))
                        .frame(width: 20)
                        .foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.title)
                            .textStyle(.bodyStrong)
                            .foregroundStyle(Theme.text)
                        Text(subtitle)
                            .textStyle(.caption)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    if let exporting {
                        BuilderRing(state: .exporting(exporting))
                    } else if copy.posted {
                        StateChip(.accepted, "Opened")
                    } else if !words.isEmpty {
                        StateChip(.proposed, "Draft")
                    }
                    Image(systemName: copy.open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(target.title), \(subtitle)")

            if copy.open { detail }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .statusOutline(copy.posted ? .accepted : .proposed, cornerRadius: Theme.Radius.lg,
                       lineWidth: copy.open ? Theme.Stroke.ring : Theme.Stroke.hairline)
        .onAppear { onMount?(target, copy) }
        .onChange(of: agents.share) { _, _ in copy.asking = false; copy.posted = false }
    }

    private var subtitle: String {
        if let file { return "\(file.preset.title) · \(file.url.lastPathComponent)" }
        return "Exports \(target.preferred.first?.title ?? "a video") first"
    }

    @ViewBuilder
    private var detail: some View {
        TextEditor(text: Binding(get: { words }, set: { copy.edit($0) }))
            .textStyle(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 72, maxHeight: 160)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.lineStrong, lineWidth: Theme.Stroke.hairline))
            .disabled(copy.posted || !copy.loaded)
        if let problem = copy.problem {
            Text(problem).textStyle(.caption).foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
            Button(copy.loaded ? "Retry saving copy" : "Retry loading copy") {
                if copy.loaded { copy.save() } else { copy.reload() }
            }.buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
        }
        if copy.asking {
            ApprovalCard(agent: "Sharer", question: PostApprovalText.question(to: target.title),
                         quote: words, options: PostApprovalText.options(scope: rules.scope),
                         onAnswer: answer, onLater: { copy.asking = false })
        } else if file == nil {
            HStack(spacing: Theme.Space.sm) {
                Button(exporting == nil ? "Export \(target.preferred.first?.title ?? "")" : "Exporting…") { export() }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                    .disabled(exporting != nil || queue.isRunning)
                if queue.isRunning, exporting == nil {
                    Text("Another export is running")
                        .textStyle(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        } else {
            HStack(spacing: Theme.Space.sm) {
                Button(copy.posted ? "Open \(target.title) again" : "Copy and open \(target.title)") {
                    if copy.posted || rules.allows(target.destination) { post() } else { copy.asking = true }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                .disabled(!copy.loaded)
                if agents.share == nil {
                    Button("Draft with Sharer") { if PostCopy.canDraft(for: take) { agents.runSharer() } }
                        .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                        .disabled(!PostCopy.canDraft(for: take) || agents.sharerRun.isRunning)
                        .help("Automatic post drafts need at least \(SharerAgent.minimumWords) kept words. You can write your own copy above.")
                }
                if rules.allows(target.destination) {
                    Button("Ask every time") { rules.forget(target.destination) }
                        .buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                }
            }
            ForEach(target.steps(file: file?.preset), id: \.self) { step in
                Text(step)
                    .textStyle(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func export() {
        guard let preset = target.preferred.first else { return }
        queue.reset()
        queue.export(take, presets: [preset], keep: nil)
    }

    private func answer(_ answer: ApprovalAnswer) {
        copy.asking = false
        switch answer {
        case .yes: post()
        case .yesAlways:
            rules.allow(target.destination)
            post()
        case let .no(feedback):
            agents.runSharer(note: feedback.isEmpty ? nil : feedback)
        }
    }

    /// Same as the export sheet's share card: record the approval, copy
    /// the words, show the file to drag in, open the composer.
    private func post() {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await AIServices.shared.gate.approvedInPlace(
                SharerAgent.postRequest(words, to: target.destination, network: target.network))
        }
        if !words.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(words, forType: .string)
        }
        if let url = file?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        NSWorkspace.shared.open(target.composer(text: words.isEmpty ? nil : words))
        copy.posted = true
    }
}

// MARK: - Link

/// The share link, once the share page is up: Copy link and WhatsApp.
private struct LinkRow: View {
    let link: URL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            PanelLabel("Link")
            HStack(spacing: Theme.Space.sm) {
                Mono(link.absoluteString.replacingOccurrences(of: "https://", with: ""))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.sm)
                Button(copied ? "Copied" : "Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    copied = true
                }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                Button("WhatsApp") {
                    NSWorkspace.shared.open(ShareTarget.whatsapp.composer(text: link.absoluteString))
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 10)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .statusOutline(.accepted, cornerRadius: Theme.Radius.lg, lineWidth: Theme.Stroke.hairline)
        }
    }
}

/// Small caps over a group, like "SOCIALS".
private struct PanelLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .textStyle(.caption)
            .tracking(0.6)
            .foregroundStyle(Theme.textMuted)
            .padding(.top, Theme.Space.xs)
    }
}
