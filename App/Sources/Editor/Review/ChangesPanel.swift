import SwiftUI
import VisionOneKit

/// The "Changes" tab: one row per group of AI suggestions, each with a
/// switch. Dashed with the switch off while proposed, solid ink with the
/// switch on once accepted, a muted line when turned off. "Accept all" turns every dashed row solid.
struct ChangesPanel: View {
    @ObservedObject var model: EditorModel
    /// Observed too, so zoom and blur rows follow their own changes.
    @ObservedObject var effects: EffectsModel
    /// Watched so a transcript that fails or restarts changes the empty state.
    @ObservedObject private var transcriber = Transcriber.shared

    var body: some View {
        let groups = model.changeGroups
        VStack(spacing: 0) {
            if groups.isEmpty {
                emptyState
                    .padding(Theme.Space.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Space.sm) {
                        ForEach(groups) { group in
                            ChangeRow(group: group) { on in model.setChange(group.kind, on: on) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                Divider().overlay(Theme.line)
                footer
            }
        }
        .background(Theme.paper)
    }

    /// Still transcribing, transcript ready with nothing to change, or no
    /// transcript at all (with a way to try again).
    private var emptyState: some View {
        let state = ChangesEmptyState.resolve(hasTranscript: model.transcriptState == .ready,
                                              failure: transcriptFailure)
        return VStack(spacing: Theme.Space.sm) {
            EditorNotice(title: state.title, message: state.message, isError: state.isError)
            if state.isError {
                Button("Try again") { retryTranscript() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .help("Transcribe this take again, on this Mac")
            }
        }
    }

    /// Why there's no transcript, or nil while it's still on its way.
    private var transcriptFailure: String? {
        if case let .failed(why) = model.transcriptState { return why }
        let take = model.take
        if let message = transcriber.failures[take.name] { return message }
        guard FileManager.default.fileExists(atPath: take.transcriptFailedURL.path) else { return nil }
        // The marker's own message; blank falls back to "nothing was heard".
        return (try? TranscriptFailure.read(from: take.transcriptFailedURL))?.message ?? ""
    }

    /// Clears the marker and queues the take again; the editor picks the
    /// transcript up when it lands.
    private func retryTranscript() {
        let take = model.take
        try? FileManager.default.removeItem(at: take.transcriptFailedURL)
        transcriber.transcribe(take)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Dashed until you accept")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: Theme.Space.sm)
            Button("Accept all") { model.acceptAllChanges() }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(model.proposedChangeCount == 0)
                .help("Accept every dashed suggestion. ⌘Z undoes it.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One group of suggestions with its switch.
private struct ChangeRow: View {
    let group: ChangeGroup
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if !group.detail.isEmpty {
                    Text(group.detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            // On only once accepted, so a dashed row never looks applied.
            Toggle(group.title, isOn: Binding(get: { group.state == .accepted }, set: set))
                .toggleStyle(InkSwitchStyle(label: "Keep: \(group.title)"))
        }
        .foregroundStyle(group.state == .off ? Theme.textMuted : Theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(group.state == .off ? Theme.line : Theme.text,
                              style: StrokeStyle(lineWidth: 1.5, dash: group.state == .proposed ? [4, 3] : []))
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .contextMenu {
            if group.state != .accepted { Button("Accept") { set(true) } }
            if group.state != .off { Button("Turn off") { set(false) } }
        }
        .help(help)
    }

    private var help: String {
        switch group.state {
        case .proposed: return "Suggested, not applied yet. Switch it on to accept, or right-click to turn it off."
        case .accepted: return "Accepted. Switch it off to bring these back."
        case .off: return "Off. Switch it on to accept these."
        }
    }
}
