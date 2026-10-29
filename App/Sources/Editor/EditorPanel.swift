import SwiftUI
import VisionOneKit

/// The editor as a panel for the frame's right-side panel host: the
/// video, play and length, then Transcript and Changes. ⤢ opens the
/// editor full mode for the same take.
struct EditorPanel: View {
    @ObservedObject var model: EditorModel
    var onExpand: (() -> Void)?

    @AppStorage("editorPanel.pane") private var paneRaw = EditorAside.transcript.rawValue

    private var pane: EditorAside {
        let picked = EditorAside(rawValue: paneRaw) ?? .transcript
        return picked == .changes ? .changes : .transcript
    }

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                EditorNotice(title: "Can't open this take", message: message, isError: true)
                    .padding(Theme.Panel.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                PlayerSurface(player: model.player)
                    .overlay { CaptionLayer(model: model) }
                    .overlay { EffectsLayer(model: model, effects: model.effects) }
                    .background(Theme.text)
                    .onTapGesture { model.togglePlay() }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding([.horizontal, .top], Theme.Panel.inset)
                transport
                    .padding(.horizontal, Theme.Panel.inset)
                    .padding(.vertical, Theme.Space.sm)
                Divider().overlay(Theme.line)
                HStack {
                    SegmentedTabs(selection: Binding(get: { pane }, set: { paneRaw = $0.rawValue }),
                                  options: [EditorAside.transcript, .changes]) { option in
                        option == .changes && model.proposedChangeCount > 0
                            ? "Changes \(model.proposedChangeCount)" : option.title
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider().overlay(Theme.line)
                switch pane {
                case .changes: ChangesPanel(model: model, effects: model.effects)
                default: TranscriptPane(model: model)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .task(id: model.take.folder) { await model.loadIfNeeded() }
    }

    private var aspect: CGFloat {
        let size = model.videoSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }

    private var transport: some View {
        HStack(spacing: Theme.Space.sm) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.text))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Text("\(Timecode.short(from: model.edits.outputTime(forSource: model.sourceTime) ?? 0)) / \(Timecode.short(from: model.edits.outputDuration))")
                .font(.system(size: 12, design: .monospaced).monospacedDigit())
                .lineLimit(1)
            Spacer(minLength: 0)
            if FileManager.default.fileExists(atPath: model.take.cameraURL.path) {
                TakeBackgroundMenu(take: model.take)
            }
            if let onExpand {
                IconButton("Open the editor", systemImage: "arrow.up.left.and.arrow.down.right", action: onExpand)
            }
        }
    }
}
