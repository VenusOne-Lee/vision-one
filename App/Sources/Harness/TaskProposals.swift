import SwiftUI
import VisionOneKit

/// The task's suggestions as one grouped card (Trim pauses, Remove filler
/// words, Captions…), then the dashed summary: how long the video becomes
/// and one button to apply everything. Each row opens Changes.
struct TaskProposals: View {
    @ObservedObject var editor: EditorModel
    let review: () -> Void
    let captions: () -> Void
    @State private var captionsOn = false

    var body: some View {
        let groups = editor.changeGroups.filter { $0.state != .off }
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if !groups.isEmpty || captionsOn {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { rowDivider }
                        SuggestionRow(icon: icon(group.kind), title: title(group.kind), detail: detail(group),
                                    count: count(group), proposed: group.state == .proposed, action: review)
                    }
                    if captionsOn {
                        if !groups.isEmpty { rowDivider }
                        SuggestionRow(icon: "captions.bubble", title: "Captions",
                                    detail: "Burned in and saved as subtitle files", count: "On",
                                    proposed: false, action: captions)
                    }
                }
                .padding(.vertical, 4)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
            }
            if editor.proposedChangeCount > 0 { summary }
        }
        .task(id: editor.take.folder) { captionsOn = editor.take.loadCaptionSettings().isOn }
        .onReceive(NotificationCenter.default.publisher(for: .takeStyleChanged)) { note in
            if note.object as? URL == editor.take.folder { captionsOn = editor.take.loadCaptionSettings().isOn }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.line).frame(height: Theme.Stroke.hairline).padding(.leading, 56)
    }

    /// "2:14 → 1:56 · 7 changes · 18 seconds saved", dashed because it's
    /// still only a proposal.
    private var summary: some View {
        let changes = editor.proposedChangeCount
        let before = editor.edits.outputDuration
        var after = editor.edits
        after.acceptAllProposed()
        let saved = max(0, before - after.outputDuration)
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(Timecode.short(from: before))
                    Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold))
                    Text(Timecode.short(from: after.outputDuration))
                }
                .font(.custom(BundledFont.sansBold, size: 24))
                .monospacedDigit()
                Text("\(changes) \(changes == 1 ? "change" : "changes")  ·  \(savedText(saved))")
                    .textStyle(.body)
                    .foregroundStyle(Theme.textMuted)
            }
            Button { editor.acceptAllChanges() } label: {
                Text("Apply \(changes) \(changes == 1 ? "change" : "changes")").frame(maxWidth: .infinity)
            }
            .buttonStyle(WideButtonStyle(kind: .primary))
            Button(action: review) {
                Text("Review individually").frame(maxWidth: .infinity)
            }
            .buttonStyle(WideButtonStyle(kind: .secondary))
        }
        .padding(Theme.Space.md)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: Theme.Stroke.hairline, dash: Theme.Stroke.dash)))
    }

    private func savedText(_ seconds: Double) -> String {
        let value = seconds >= 1 ? "\(Int(seconds.rounded()))" : String(format: "%.1f", seconds)
        return "\(value) \(value == "1" ? "second" : "seconds") saved"
    }

    private func icon(_ kind: ChangeGroup.Kind) -> String {
        switch kind {
        case .pauses: return "sparkles"
        case .fillers: return "quote.closing"
        case .retakes: return "arrow.uturn.backward"
        case .deadAir: return "speaker.slash"
        case .trims: return "scissors"
        case .zooms: return "plus.magnifyingglass"
        case .blurs: return "eye.slash"
        case .soundEffects: return "music.note"
        }
    }

    private func title(_ kind: ChangeGroup.Kind) -> String {
        switch kind {
        case .pauses: return "Trim pauses"
        case .fillers: return "Remove filler words"
        case .retakes: return "Keep your last take"
        case .deadAir: return "Trim silence at the ends"
        case .trims: return "Suggested cuts"
        case .zooms: return "Zoom on clicks"
        case .blurs: return "Blur secrets"
        case .soundEffects: return "Add sound effects"
        }
    }

    private func detail(_ group: ChangeGroup) -> String {
        switch group.kind {
        case .pauses: return "Remove awkward silences"
        case .fillers:
            let words = group.detail.components(separatedBy: " · ").first ?? ""
            return words.isEmpty || words.hasPrefix("−") ? "Like “um” and “uh”" : "Like \(words)"
        default: return group.title
        }
    }

    private func count(_ group: ChangeGroup) -> String {
        let n = group.count
        switch group.kind {
        case .zooms: return "\(n) \(n == 1 ? "zoom" : "zooms")"
        case .blurs: return "\(n) \(n == 1 ? "blur" : "blurs")"
        case .soundEffects: return "\(n) \(n == 1 ? "effect" : "effects")"
        default: return "\(n) \(n == 1 ? "cut" : "cuts")"
        }
    }
}

/// One suggestion: icon, title, a muted line, how many, chevron. Dashed
/// icon tile while it waits, solid once kept.
struct SuggestionRow: View {
    let icon: String
    let title: String
    let detail: String
    let count: String
    let proposed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.text)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.custom(BundledFont.sansMedium, size: 14))
                    Text(detail).textStyle(.body).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.sm)
                Text(count).textStyle(.body).foregroundStyle(Theme.textMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 12)
            .background(hovering ? Theme.canvas.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(count)\(proposed ? ", proposed" : "")")
        .accessibilityHint("Opens Changes")
    }
}

/// A full-width rounded button: black for the main action, outlined for
/// the other.
struct WideButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    var height: CGFloat = 42

    func makeBody(configuration: Configuration) -> some View {
        WideButton(configuration: configuration, kind: kind, height: height)
    }

    private struct WideButton: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.custom(BundledFont.sansSemiBold, size: 15))
                .foregroundStyle(kind == .primary ? Theme.onButton : Theme.text)
                .padding(.horizontal, Theme.Space.md)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(kind == .primary ? Theme.button : Theme.paper))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(kind == .primary ? .clear : Theme.lineStrong, lineWidth: Theme.Stroke.hairline))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }
    }
}
