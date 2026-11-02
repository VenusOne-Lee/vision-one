import AVFoundation
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

    @State private var showMore = true

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let clip = clips.selected {
                        ClipDeliveryPreview(model: clips, clip: clip,
                                            height: max(260, min(560, geometry.size.height * 0.55)), showsRenderAction: false)
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)
                            ForEach([ClipFormat.landscape, .vertical, .square], id: \.self) { format in
                                formatButton(format, isOn: clip.format == format) { clips.setFormat(format, for: clip.id) }
                            }
                            Spacer(minLength: 0)
                        }
                        exportCard(clip)
                        deliveryState(clip)
                        if let problem = captionControl.problem { Text(problem).textStyle(.caption).foregroundStyle(Theme.error) }
                        DisclosureGroup("Trim, framing and clip details") {
                            ClipCard(model: clips, clip: clip, isSelected: true).padding(.top, 8)
                        }.textStyle(.label)
                        DisclosureGroup("All clips") { ClipsPane(model: clips).frame(height: 350) }
                            .textStyle(.label)
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

    private func formatButton(_ format: ClipFormat, isOn: Bool, action: @escaping () -> Void) -> some View {
        let title: String
        let icon: String
        switch format {
        case .landscape: title = "Original"; icon = "rectangle"
        case .vertical: title = "Vertical"; icon = "rectangle.portrait"
        case .square: title = "Square"; icon = "square"
        }
        return Button(action: action) {
            Label(title, systemImage: icon)
                .font(.custom(BundledFont.sansMedium, size: 14))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(isOn ? Theme.canvas : Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(isOn ? Theme.text : Theme.line, lineWidth: isOn ? 1.5 : Theme.Stroke.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// 1080p, captions, a size estimate and Export clip; then the other ways out.
    private func exportCard(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.md) { exportRow(clip) }
                VStack(alignment: .leading, spacing: Theme.Space.sm) { exportRow(clip) }
            }
            Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
            Button { showMore.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showMore ? 0 : -90))
                    Text("More export options").font(.custom(BundledFont.sansMedium, size: 14))
                    Spacer()
                }
                .foregroundStyle(Theme.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showMore {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.md) { moreOptions }
                    VStack(alignment: .leading, spacing: Theme.Space.sm) { moreOptions }
                }
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
    }

    @ViewBuilder private func exportRow(_ clip: Clip) -> some View {
        Text("1080p")
            .font(.custom(BundledFont.sansMedium, size: 14))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
            .help("Clips export at 1080p")
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble").font(.system(size: 15))
            Text("Captions").font(.custom(BundledFont.sansMedium, size: 14))
            Toggle("", isOn: Binding(get: { captionControl.isOn }, set: { captionControl.set($0) }))
                .labelsHidden().toggleStyle(.ink)
                .accessibilityLabel("Captions")
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("Estimated size").textStyle(.caption).foregroundStyle(Theme.textMuted)
            // About 8 Mbit/s at 1080p: one megabyte a second.
            Text("\(max(1, Int((clip.end - clip.start).rounded()))) MB").font(.custom(BundledFont.sansMedium, size: 14))
        }
        .help("A rough guide: about 1 MB a second at 1080p")
        Spacer(minLength: 0)
        if clip.state == .proposed {
            Button("Keep clip") { clips.accept(clip.id) }
                .buttonStyle(WideButtonStyle(kind: .primary)).fixedSize()
        } else {
            Button("Export clip") { clips.export(clip) }
                .buttonStyle(WideButtonStyle(kind: .primary)).fixedSize()
                .disabled(clips.isExporting)
        }
    }

    @ViewBuilder private var moreOptions: some View {
        option("WhatsApp", "(optimized)", icon: "paperplane") { model.presentingExport = true }
        option("Subtitle files", "(SRT, VTT)", icon: "doc.text") { model.updateLayout { $0.show(.captions) } }
        option("Languages & versions", "Create dubs or personal versions", icon: "character.bubble") {
            LanguagesWindowController.shared.show(for: workspace.take)
        }
    }

    private func option(_ title: String, _ detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 38, height: 38)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.custom(BundledFont.sansMedium, size: 13))
                    Text(detail).textStyle(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
            }
            .foregroundStyle(Theme.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Suggested clips").font(.custom(BundledFont.sansSemiBold, size: 16))
                    Spacer()
                    let count = clips.list.visible.count
                    Text("\(count) \(count == 1 ? "clip" : "clips")").textStyle(.body).foregroundStyle(Theme.textMuted)
                }
                if clips.list.visible.isEmpty {
                    Text("No clips yet. Ask for clips, or add one at the playhead in Clips.")
                        .textStyle(.body).foregroundStyle(Theme.textMuted)
                }
                ForEach(clips.list.visible) { clip in
                    ClipThreadRow(take: workspace.take, clip: clip, isSelected: clips.selectedID == clip.id) {
                        clips.selectedID = clip.id
                    }
                }
            }
            .padding(Theme.Space.md)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
            VStack(alignment: .leading, spacing: 10) {
                Text("Post copy").font(.custom(BundledFont.sansSemiBold, size: 16))
                PostPanel(take: workspace.take).frame(height: 360)
            }
            .padding(Theme.Space.md)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
        }
    }
}

/// One suggested clip: frame with its length, "00:24 → 00:54", title,
/// why, chevron. The picked one is outlined; a proposal is dashed.
struct ClipThreadRow: View {
    let take: Take
    let clip: Clip
    let isSelected: Bool
    let select: () -> Void
    @State private var frame: CGImage?

    var body: some View {
        Button(action: select) {
            HStack(spacing: 14) {
                Color.clear
                    .frame(width: 130, height: 90)
                    .background(Theme.canvas)
                    .overlay { if let frame { Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fill) } }
                    .overlay(alignment: .bottomTrailing) {
                        Text(Timecode.short(from: clip.end - clip.start))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .padding(6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stamp(clip.start))  →  \(stamp(clip.end))")
                        .font(.custom(BundledFont.monoRegular, size: 12))
                        .foregroundStyle(Theme.textMuted)
                    Text(clip.title).font(.custom(BundledFont.sansSemiBold, size: 14)).lineLimit(1)
                    if let why = clip.hook ?? clip.reason {
                        Text(why).textStyle(.body).foregroundStyle(Theme.textMuted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(
                isSelected ? Theme.text : Theme.line,
                style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: clip.state == .proposed ? Theme.Stroke.dash : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: clip.start) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: take.screenURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 200)
            frame = try? await generator.image(at: CMTime(seconds: clip.start + 0.1, preferredTimescale: 600)).image
        }
    }

    private func stamp(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
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
