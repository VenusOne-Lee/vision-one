import SwiftUI
import VisionOneKit

/// Editor or Sound (or "Clips from my last video") with nothing recorded
/// yet: say what goes here and offer the one next step, recording.
struct NoTakesYetView: View {
    let mode: HarnessMode
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        EmptyState(title, message: message,
                   action: (title: recorder.phase.isLive ? "Stop recording" : "Record your first take",
                            run: { Task { await ScreenRecorder.shared.toggle() } }))
            .disabled(recorder.phase.isBusy)
            .background(Theme.canvas)
    }

    private var title: String {
        switch mode {
        case .sound: return "No sound to mix yet"
        case .editor, .tasks: return "Nothing to edit yet"
        }
    }

    private var message: String {
        if recorder.phase.isLive {
            return "You're recording. Stop when you're done and your take opens here."
        }
        switch mode {
        case .sound: return "Music and effects go under a take. Record one and it opens here."
        case .editor, .tasks: return "Record a take and you edit it here by editing its words. ⇧⌘R works from anywhere."
        }
    }
}

/// New task before anything is recorded: one calm line pointing at the
/// record button in the composer. Asking for clips with nothing recorded
/// says why instead of doing nothing.
struct FirstTakeHint: View {
    /// Set when something needed a take ("Clips from my last video").
    let neededTake: Bool
    @ObservedObject private var recorder = ScreenRecorder.shared

    var body: some View {
        if !recorder.phase.isLive {
            HStack(spacing: Theme.Space.sm) {
                Text(neededTake
                     ? "Clips need a take to cut from. Record your first one above, then ask again."
                     : "No takes yet. Press record below, or ⇧⌘R from anywhere, to make your first.")
                    .textStyle(.body)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 640)
            .accessibilityElement(children: .contain)
        }
    }
}

/// "No AI is set up yet" with a link to AI settings and ×, above the
/// composer on New task. One line, shown only when no rung is ready, and
/// gone for good once closed.
struct AISetupNoticeRow: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(AISetupNotice.text)
                .textStyle(.caption)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(AISetupNotice.action) { SettingsWindowController.shared.show(.ai) }
                .buttonStyle(.plain)
                .textStyle(.caption)
                .foregroundStyle(Theme.text)
                .underline()
                .help("Sign in with ChatGPT, turn on Apple Intelligence, or add a key")
            Spacer(minLength: 0)
            IconButton("Don't show this again", systemImage: "xmark", action: dismiss)
        }
        .padding(.leading, Theme.Space.sm + 4)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, 2)
        .frame(maxWidth: 640)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.line, lineWidth: Theme.Stroke.hairline))
    }
}

/// What the AI notice re-checks on: a change in settings, keys, the
/// ChatGPT sign-in or the local server.
struct AIReadinessKey: Equatable {
    var settings: AISettings
    var keys: Int
    var account: String?
    var localModel: String

    @MainActor
    init(_ ai: AIServices) {
        settings = ai.settings
        keys = ai.keysVersion
        account = ai.chatGPTAccount
        localModel = ai.localModel
    }
}
