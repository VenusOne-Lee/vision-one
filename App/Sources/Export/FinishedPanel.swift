import AppKit
import SwiftUI
import VisionOneKit

/// The export sheet once it's done: every file ready to drag out, copy or
/// share, then the places to post it. Tapping a place opens its post as
/// a dashed card with the Sharer's words, editable; approving it turns
/// the card solid, copies the words, shows the right file in Finder and
/// opens the network's composer. Nothing posts by itself.
struct FinishedPanel: View {
    let take: Take
    let batch: ExportBatch
    /// The shape each preset came out in.
    let aspect: (ExportPreset) -> Double

    @StateObject private var agents: AgentsModel
    @State private var sharing: ShareTarget?
    @State private var draft = ""
    @State private var approved: ShareTarget?
    @State private var copied: ExportPreset?

    init(take: Take, batch: ExportBatch, aspect: @escaping (ExportPreset) -> Double) {
        self.take = take
        self.batch = batch
        self.aspect = aspect
        _agents = StateObject(wrappedValue: AgentsModel(take: take))
    }

    private struct DoneFile: Identifiable {
        let preset: ExportPreset
        let url: URL
        let bytes: Int64
        var id: ExportPreset { preset }
    }

    private var done: [DoneFile] {
        batch.presets.compactMap { preset in
            if case let .done(url, bytes)? = batch.status(of: preset) {
                return DoneFile(preset: preset, url: url, bytes: bytes)
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(done.count == 1 ? "1 video ready" : "\(done.count) videos ready")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: Theme.Space.sm)
                Text("Drag a file straight into WhatsApp, Slack or Mail")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            VStack(spacing: Theme.Space.sm) {
                ForEach(done) { file in
                    FileRow(preset: file.preset, url: file.url, bytes: file.bytes,
                            aspect: aspect(file.preset), copied: copied == file.preset) {
                        copy(file.url, preset: file.preset)
                    }
                }
            }
            if !batch.failures.isEmpty {
                Text(batch.failures.joined(separator: "\n"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("SHARE TO")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, Theme.Space.xs)
            if let sharing {
                approvalCard(sharing)
            } else {
                targets
            }
        }
        .onChange(of: agents.share) { _, pack in
            // A fresh draft from the Sharer fills the open card.
            if let sharing, let text = sharing.text(in: pack) { draft = text }
        }
    }

    // MARK: - Targets

    private var targets: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(ShareTarget.allCases) { target in
                let file = target.file(from: batch.files)
                Button {
                    open(target)
                } label: {
                    TargetLabel(icon: Self.icon(target), title: target.title,
                                detail: file.map { $0.preset.title } ?? "")
                }
                .buttonStyle(.plain)
                .disabled(file == nil)
                .help("Post the \(file?.preset.title ?? "") video to \(target.title)")
            }
            if let first = done.first {
                // The Mac's own share menu: AirDrop, Messages, Mail, Notes.
                ShareLink(item: first.url) {
                    TargetLabel(icon: "square.and.arrow.up", title: "More", detail: "AirDrop, Mail…")
                }
                .buttonStyle(.plain)
                .help("Share the \(first.preset.title) video another way")
            }
        }
    }

    private func open(_ target: ShareTarget) {
        sharing = target
        approved = nil
        draft = target.text(in: agents.share) ?? ""
    }

    // MARK: - Approval

    private func approvalCard(_ target: ShareTarget) -> some View {
        let file = target.file(from: batch.files)
        let isApproved = approved == target
        let fromSharer = agents.share.flatMap { target.text(in: $0) } != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Post to \(target.title)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: Theme.Space.sm)
                Text(isApproved ? "Approved" : (fromSharer ? "Sharer draft · not posted" : "Not posted"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 84, maxHeight: 160)
                if draft.isEmpty {
                    Text(target == .youtube ? "Title, description and chapters" : "Write the post, or let the Sharer draft it")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: 1))
            .disabled(isApproved)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(target.steps(file: file?.preset), id: \.self) { step in
                    Label(step, systemImage: "checkmark")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            RunStatus(run: agents.sharerRun)
            HStack(spacing: Theme.Space.sm) {
                Button(isApproved ? "Opened \(target.title)" : "Approve and open \(target.title)") {
                    approve(target, file: file?.url)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(isApproved)
                Button(agents.share == nil ? "Draft with Sharer" : "Write again") { agents.runSharer() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(isRunning || isApproved)
                    .help("The Sharer writes a title, description, chapters and a post for each network")
                Spacer(minLength: 0)
                Button(isApproved ? "Share somewhere else" : "Back") { sharing = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            // Dashed while it waits for you, solid once approved.
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: isApproved ? [] : [5, 4]))
        )
    }

    private var isRunning: Bool {
        if case .running = agents.sharerRun { return true }
        return false
    }

    /// The card showed the exact words and where they go, so pressing
    /// Approve is the approval: it's recorded with the gate rather than
    /// asked again in a second panel.
    private func approve(_ target: ShareTarget, file: URL?) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        approved = target
        Task {
            await AIServices.shared.gate.approvedInPlace(
                SharerAgent.postRequest(text, to: target.destination, network: target.network))
        }
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        NSWorkspace.shared.open(target.composer(text: text.isEmpty ? nil : text))
    }

    // MARK: - Copy

    /// Puts the file itself on the clipboard, so ⌘V pastes the video into
    /// WhatsApp, Slack, Mail or Finder.
    private func copy(_ url: URL, preset: ExportPreset) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        copied = preset
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == preset { copied = nil }
        }
    }

    static func icon(_ target: ShareTarget) -> String {
        switch target {
        case .whatsapp: return "bubble.left"
        case .linkedin: return "person.crop.square"
        case .x: return "xmark"
        case .youtube: return "play.rectangle"
        }
    }
}

// MARK: - File row

/// One finished file: its shape (drag it out), name and size, Copy and Show.
private struct FileRow: View {
    let preset: ExportPreset
    let url: URL
    let bytes: Int64
    let aspect: Double
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(preset.title) · \(ExportPhase.size(bytes))")
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: Theme.Space.sm)
            Button(copied ? "Copied" : "Copy", action: copy)
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help("Copy the video, then paste it into a chat or email")
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help("Show in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        // The whole row drags the file, like a Finder icon.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("Drag into WhatsApp, Slack, Mail or Finder")
    }

    private var thumb: some View {
        let box = CGSize(width: 52, height: 36)
        let a = max(aspect, 0.1)
        let width = min(box.width, box.height * a)
        return ZStack {
            Color.clear.frame(width: box.width, height: box.height)
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.canvas)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.text, lineWidth: 1.5))
                .frame(width: width, height: width / a)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Target label

private struct TargetLabel: View {
    let icon: String
    let title: String
    let detail: String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .frame(height: 22)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .opacity(isEnabled ? 1 : 0.45)
    }
}
