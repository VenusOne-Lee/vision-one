import AppKit
import SwiftUI
import VisionOneKit

/// The panel that drops down from the menu bar. Ink on paper; the only
/// orange is the record dot and, while live, the button border.
struct MenuContent: View {
    @EnvironmentObject private var recorder: ScreenRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                Text("vision one")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌘⇧R")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }

            HStack(spacing: Theme.Space.md) {
                RecordButton(phase: recorder.phase) {
                    Task { await recorder.toggle() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Timecode.string(from: recorder.phase.elapsed(at: context.date) ?? 0))
                            .font(.system(size: 12, design: .monospaced).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }

            if case let .failed(message) = recorder.phase {
                ErrorAlert(message: message) { recorder.openScreenRecordingSettings() }
            }

            Divider().overlay(Theme.line)

            HStack {
                Button("Show recordings") { recorder.revealRecordings() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.Space.md)
        .frame(width: 280)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
    }

    private var statusTitle: String {
        switch recorder.phase {
        case .idle: return "Record whole screen"
        case .preparing: return "Getting ready…"
        case .recording: return "Recording"
        case .finishing: return "Saving…"
        case .failed: return "Couldn't record"
        }
    }
}

/// White circle, ink border, orange dot. While live the border turns
/// orange and the dot becomes an ink stop square.
struct RecordButton: View {
    let phase: RecordingPhase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.paper)
                Circle()
                    .strokeBorder(phase.isLive ? Theme.tally : Theme.text, lineWidth: 2)
                if phase.isLive {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.text)
                        .frame(width: 14, height: 14)
                } else {
                    Circle()
                        .fill(Theme.tally)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(phase.isBusy)
        .accessibilityLabel(phase.isLive ? "Stop recording" : "Start recording")
    }
}

struct ErrorAlert: View {
    let message: String
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings", action: openSettings)
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.errorSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}
