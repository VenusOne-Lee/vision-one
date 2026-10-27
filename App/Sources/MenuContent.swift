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

            CapturePicker()
                .disabled(recorder.phase.isLive || recorder.phase.isBusy)

            if case let .failed(message) = recorder.phase {
                ErrorAlert(message: message) { recorder.openSetup() }
            }

            Divider().overlay(Theme.line)

            HStack {
                Button("Show recordings") { recorder.revealRecordings() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Button("Access") { recorder.openSetup() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
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
        case .idle: return "Record \(recorder.choice.mode.title.lowercased())"
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
            Button("Check access", action: openSettings)
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .padding(Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.errorSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// Screen, Window or Area, then what to record within it, and which
/// sound. Changes are saved for the next take.
struct CapturePicker: View {
    @EnvironmentObject private var recorder: ScreenRecorder
    @State private var windows: [WindowCandidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ModeSwitch(selection: $recorder.choice.mode)

            switch recorder.choice.mode {
            case .screen:
                if NSScreen.screens.count > 1 { displayPicker }
            case .window:
                windowPicker
            case .area:
                areaRow
            }

            HStack(spacing: Theme.Space.md) {
                Toggle("Mic", isOn: $recorder.choice.includeMicrophone)
                Toggle("System sound", isOn: $recorder.choice.includeSystemSound)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.text)
            .font(.system(size: 12))
        }
    }

    private var displayPicker: some View {
        Picker("Screen", selection: Binding(
            get: { recorder.choice.displayID ?? CGMainDisplayID() },
            set: { recorder.choice.displayID = $0 }
        )) {
            ForEach(NSScreen.screens, id: \.self) { screen in
                if let id = screen.displayID {
                    Text(screen.localizedName).tag(id)
                }
            }
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
    }

    private var windowPicker: some View {
        Picker("Window", selection: $recorder.choice.windowID) {
            Text("Choose a window").tag(UInt32?.none)
            ForEach(windows) { window in
                Text(window.label).tag(UInt32?.some(window.id))
            }
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .task { windows = await recorder.pickableWindows() }
    }

    private var areaRow: some View {
        HStack {
            if let area = recorder.choice.area {
                Text("\(Int(area.width)) × \(Int(area.height))")
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
            } else {
                Text("No area yet")
                    .font(.system(size: 12))
            }
            Spacer()
            Button(recorder.choice.area == nil ? "Choose area" : "Change area") {
                recorder.chooseArea()
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
        }
        .foregroundStyle(Theme.textMuted)
    }
}

/// Three ink segments. The chosen one is a black pill, like a primary
/// button; the others are plain text.
private struct ModeSwitch: View {
    @Binding var selection: CaptureMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == mode ? Theme.paper : Theme.text)
                        .background(Capsule().fill(selection == mode ? Theme.text : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }
}
