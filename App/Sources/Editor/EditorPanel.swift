import SwiftUI
import VisionOneKit

/// The editor as a panel for the frame's right-side panel host: the
/// video, play and length, then Transcript and Changes. ⤢ opens the
/// editor full mode for the same take.
struct EditorPanel: View {
    @ObservedObject var model: EditorModel
    var onExpand: (() -> Void)?

    @AppStorage("editorPanel.pane") private var paneRaw = EditorAside.transcript.rawValue
    @State private var search = ""
    @State private var searching = false

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
                VideoStage(model: model, onExpand: onExpand)
                    .padding([.horizontal, .top], Theme.Space.md)
                HStack(spacing: Theme.Space.sm) {
                    SegmentBar(selection: Binding(get: { pane }, set: { paneRaw = $0.rawValue }),
                               options: [EditorAside.transcript, .changes], fill: false) { option in
                        option == .changes && model.proposedChangeCount > 0
                            ? "Changes (\(model.proposedChangeCount))" : option.title
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                    if pane == .transcript { TranscriptSearchButton(query: $search, isOpen: $searching) }
                }
                .padding(.horizontal, Theme.Space.md)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)
                Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline)
                switch pane {
                case .changes: ChangesPanel(model: model, effects: model.effects)
                default: TranscriptPane(model: model, search: search)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .task(id: model.take.folder) { await model.loadIfNeeded() }
    }
}
