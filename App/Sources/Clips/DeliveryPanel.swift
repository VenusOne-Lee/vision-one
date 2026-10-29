import SwiftUI
import VisionOneKit

/// The selected clip is the focus; format, captions and export stay beside it.
/// Other components remain available through the workspace's panel tabs.
struct DeliveryPanel: View {
    @ObservedObject var workspace: TaskWorkspace
    @ObservedObject var model: HarnessModel
    @ObservedObject private var clips: ClipsModel
    @StateObject private var captionControl: DeliveryCaptionControl
    @Environment(\.workspaceRender) private var workspaceRender

    init(workspace: TaskWorkspace, model: HarnessModel) {
        self.workspace = workspace
        self.model = model
        self.clips = workspace.clips
        _captionControl = StateObject(wrappedValue: DeliveryCaptionControl(take: workspace.take))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let clip = clips.selected {
                        ClipDeliveryPreview(model: clips, clip: clip,
                                            height: max(260, min(520, geometry.size.height * 0.58)), showsRenderAction: false)
                        SegmentedTabs(selection: Binding(get: { clip.format }, set: { clips.setFormat($0, for: clip.id) }),
                                      options: [ClipFormat.landscape, .vertical, .square]) { format in
                            switch format { case .landscape: return "Original"; case .vertical: return "Vertical"; case .square: return "Square" }
                        }
                        HStack(spacing: 12) {
                            Text("1080p").textStyle(.label)
                            Toggle("Captions", isOn: Binding(get: { captionControl.isOn }, set: { captionControl.set($0) })).toggleStyle(.ink)
                            Spacer(minLength: 0)
                            if clip.state == .proposed {
                                Button("Keep clip") { clips.accept(clip.id) }.buttonStyle(.primary)
                            } else {
                                Button("Export clip") { clips.export(clip) }
                                    .buttonStyle(.primary).disabled(clips.isExporting)
                            }
                        }
                        deliveryState(clip)
                        if let problem = captionControl.problem { Text(problem).textStyle(.caption).foregroundStyle(Theme.error) }
                        DisclosureGroup("Trim, framing and clip details") {
                            ClipCard(model: clips, clip: clip, isSelected: true).padding(.top, 8)
                        }.textStyle(.label)
                        Divider().overlay(Theme.line)
                        handoffs
                        DisclosureGroup("All clips") { ClipsPane(model: clips).frame(height: 350) }
                    } else {
                        ClipsPane(model: clips).frame(minHeight: 360)
                    }
                }.padding(16)
            }
        }
        .onAppear {
            captionControl.reload()
            if workspaceRender { WorkspaceRenderEvidence.captionOwner = captionControl }
        }
    }

    @ViewBuilder private func deliveryState(_ clip: Clip) -> some View {
        switch clips.exports[clip.id] {
        case let .exporting(progress):
            HStack { ProgressView(value: progress); Button("Cancel") { clips.cancelExport() }.buttonStyle(.secondary) }
        case let .failed(message):
            Text(message).textStyle(.caption).foregroundStyle(Theme.error)
            Button("Retry export") { clips.export(clip) }.buttonStyle(.secondary)
        case .done:
            Button("Show exported file") { clips.reveal(clip.id) }.buttonStyle(.secondary)
        case nil:
            if clips.cancelledIDs.contains(clip.id) { Text("Export cancelled. Export again to retry.").textStyle(.caption) }
        }
        if let warning = clips.warnings[clip.id] { Text(warning).textStyle(.caption).foregroundStyle(Theme.error) }
    }

    private var handoffs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish and share").textStyle(.bodyStrong)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { handoffButtons }
                VStack(alignment: .leading, spacing: 12) { handoffButtons }
            }
            Text("Posts are drafts. Review and approve each handoff; Vision One copies the text and opens the destination.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
        }
    }
    @ViewBuilder private var handoffButtons: some View {
        Button("Thumbnail") { model.updateLayout { $0.show(.thumbnail) } }.buttonStyle(.secondary)
        Button("Post copy and share") { model.updateLayout { $0.show(.post) } }.buttonStyle(.secondary)
        Button("Languages and versions") { LanguagesWindowController.shared.show(for: workspace.take) }.buttonStyle(.secondary)
    }
}

/// Reviewable candidates and the real post-copy tools stay in the conversation.
struct DeliveryReview: View {
    @ObservedObject var workspace: TaskWorkspace
    @ObservedObject private var clips: ClipsModel
    init(workspace: TaskWorkspace) {
        self.workspace = workspace
        self.clips = workspace.clips
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggested clips").textStyle(.headline)
            ForEach(clips.list.visible) { clip in
                Button { clips.selectedID = clip.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle").font(.system(size: 24))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.title).textStyle(.bodyStrong)
                            Text("\(Timecode.short(from: clip.start)) → \(Timecode.short(from: clip.end)) · \(clip.format.title)")
                                .textStyle(.caption).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(12)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(
                        clips.selectedID == clip.id ? Theme.selection : Theme.line,
                        style: StrokeStyle(lineWidth: 1, dash: clip.state == .proposed ? Theme.Stroke.dash : [])))
                }.buttonStyle(.plain)
            }
            Text("Post copy").textStyle(.headline)
            PostPanel(take: workspace.take).frame(height: 360)
        }
    }
}

/// The production toggle's small state owner also receives editor/template
/// notifications. Reload is read-only, so our own notification cannot loop.
@MainActor
final class DeliveryCaptionControl: ObservableObject {
    let take: Take
    @Published private(set) var isOn = true
    @Published private(set) var problem: String?
    private var observer: NSObjectProtocol?

    init(take: Take) {
        self.take = take
        reload()
        observer = NotificationCenter.default.addObserver(forName: .takeStyleChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? URL == self.take.folder else { return }
                self.reload()
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() { isOn = take.loadCaptionSettings().isOn }

    func set(_ value: Bool) {
        do {
            isOn = try take.setCaptionVisibility(value).isOn
            problem = nil
            NotificationCenter.default.post(name: .takeStyleChanged, object: take.folder)
        } catch {
            reload()
            problem = "Couldn't save captions: \(error.localizedDescription)"
        }
    }
}
