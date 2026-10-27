import AppKit
import AVFoundation
import SwiftUI
import VisionOneKit

/// The panel that drops down from the menu bar: what to record, which
/// sources, one big record button, then the last take. Ink on paper; the
/// only orange is the menu ring, the button border and the dot while live.
/// Each section folds to a one-line summary and stays how you left it.
struct MenuContent: View {
    @EnvironmentObject private var recorder: ScreenRecorder
    @ObservedObject private var exports = ExportController.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var microphones = Microphones.shared
    @ObservedObject private var hotKey = GlobalHotKey.shared
    @ObservedObject private var devices = CaptureDevices.shared
    @AppStorage("panel.recordOpen") private var recordOpen = true
    @AppStorage("panel.sourcesOpen") private var sourcesOpen = true
    @AppStorage("panel.takeOpen") private var takeOpen = true
    @AppStorage("panel.tasksOpen") private var tasksOpen = true
    @ObservedObject private var desk = DeskFeed.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                PanelRing(isLive: recorder.phase.isLive)
                Text("Vision One")
                    .font(.system(size: 13, weight: .semibold))
                UpdateBadge(updater: updater)
                Spacer(minLength: 0)
                FooterLink("Open Vision One", action: MenuPanel.closing { EditorWindowController.shared.show() })
            }
            .padding(.horizontal, Theme.Panel.inset)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Choices fold away while recording, so nothing changes mid-take.
            PanelSection(title: "Record", summary: recordSummary, isOpen: $recordOpen, locked: isLocked) {
                CapturePicker()
            }
            PanelSection(title: "Sources", summary: sourcesSummary, isOpen: $sourcesOpen, locked: isLocked) {
                SourcesList()
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if case let .failed(message) = recorder.phase {
                    ErrorAlert(message: message, openSettings: MenuPanel.closing { recorder.openSetup() })
                }
                // The panel closes so it isn't sitting over what you record,
                // and so the editor that opens after a take comes up in front.
                RecordBar(phase: recorder.phase, title: idleTitle, action: MenuPanel.closing {
                    Task { await recorder.toggle() }
                })
                .help(hotKey.isRegistered ? "" : "⌘⇧R is taken by another app")
                if !hotKey.isRegistered {
                    Text("⌘⇧R is taken by another app. Use this button to record.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(recorder.trackNotes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !recorder.phase.isLive {
                    PanelAskBox(feed: desk)
                    FooterLink("Before you record…", action: MenuPanel.closing { EditorWindowController.shared.showNewTask() })
                }
            }
            .padding(.horizontal, Theme.Panel.inset)
            .padding(.top, 4)
            .padding(.bottom, 14)

            // Tasks from the Desk, the ones waiting on you first. Until the
            // first task exists, the last take stands in.
            if desk.hasTasks, !recorder.phase.isLive {
                PanelSection(title: "Tasks", summary: desk.summary, isOpen: $tasksOpen) {
                    PanelTasksList(feed: desk)
                }
            } else if let take = recorder.lastTake, !recorder.phase.isLive {
                PanelSection(title: "Last take", summary: take.shortLabel(), isOpen: $takeOpen) {
                    LastTakeCard(take: take, exports: exports, transcriber: transcriber,
                                 isBusy: recorder.phase.isBusy)
                }
            }

            HStack(spacing: 14) {
                FooterLink("All recordings", action: MenuPanel.closing { recorder.revealRecordings() })
                FooterLink("Settings", action: MenuPanel.closing { SettingsWindowController.shared.show() })
                Spacer(minLength: 0)
                FooterLink("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, Theme.Panel.inset)
            .padding(.vertical, Theme.Space.sm)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: Theme.Panel.width)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light) // light only, always
        .background(PanelWindowReader())
    }

    private var isLocked: Bool { recorder.phase.isLive || recorder.phase.isBusy }

    private var idleTitle: String {
        switch recorder.choice.missingStep {
        case .pickWindow: return "Pick a window first"
        case .dragArea: return "Choose an area to record"
        case nil: return "Record \(recorder.choice.mode.title.lowercased())"
        }
    }

    private var recordSummary: String {
        let choice = recorder.choice
        switch choice.mode {
        case .screen:
            let id = choice.displayID ?? CGMainDisplayID()
            let name = NSScreen.screens.first { $0.displayID == id }?.localizedName
            return name.map { "Screen · \($0)" } ?? "Screen"
        case .window:
            return choice.windowID == nil ? "Window · none picked" : "Window"
        case .area:
            guard let area = choice.area else { return "Area · none yet" }
            return "Area · \(Int(area.width)) × \(Int(area.height))"
        }
    }

    private var sourcesSummary: String {
        var on: [String] = []
        if recorder.choice.includeMicrophone {
            on.append(microphones.resolved(for: recorder.choice)?.name ?? "Mic")
        }
        if recorder.choice.includeSystemSound { on.append("Sound") }
        if devices.cameraChoice != .off { on.append("Camera") }
        return on.isEmpty ? "Video only" : on.joined(separator: " · ")
    }
}

/// The builder's ring, small: dashed while idle, orange and solid while
/// live, like the menu bar icon.
private struct PanelRing: View {
    let isLive: Bool

    var body: some View {
        ZStack {
            if isLive {
                Circle().strokeBorder(Theme.tally, lineWidth: 2)
                Circle().fill(Theme.tally).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A titled part of the panel with a hairline above it. Click the title
/// to fold it to a one-line summary; `locked` keeps it folded.
private struct PanelSection<Content: View>: View {
    let title: String
    let summary: String
    @Binding var isOpen: Bool
    var locked = false
    let content: Content

    init(title: String, summary: String, isOpen: Binding<Bool>, locked: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self._isOpen = isOpen
        self.locked = locked
        self.content = content()
    }

    private var open: Bool { isOpen && !locked }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.66)
                    Spacer(minLength: Theme.Space.sm)
                    if !open {
                        Text(summary)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .foregroundStyle(Theme.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityLabel(title)
            .accessibilityValue(open ? "Shown" : summary)

            if open { content }
        }
        .padding(.horizontal, Theme.Panel.inset)
        .padding(.top, 10)
        .padding(.bottom, open ? 12 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// One wide button. Idle it's a black pill with a hollow dot, ink like
/// every other button. Live it turns white with an orange border, a
/// blinking orange dot, the running time and Stop.
struct RecordBar: View {
    let phase: RecordingPhase
    let title: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if phase.isLive {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Theme.tally)
                                .frame(width: 12, height: 12)
                                .opacity(blinkOn(at: context.date) ? 1 : 0.25)
                            Text(Timecode.string(from: phase.elapsed(at: context.date) ?? 0))
                                .font(.system(size: 13, weight: .medium, design: .monospaced).monospacedDigit())
                        }
                    }
                    Spacer(minLength: Theme.Space.sm)
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.text)
                            .frame(width: 10, height: 10)
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                } else if phase.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.paper)
                    Text(busyTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                } else {
                    Circle()
                        .strokeBorder(Theme.paper, lineWidth: 2)
                        .frame(width: 14, height: 14)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                    Text("⌘⇧R")
                        .font(.system(size: 11, design: .monospaced))
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(phase.isLive ? Theme.text : Theme.paper)
            .background(Capsule().fill(phase.isLive ? Theme.paper : Theme.text))
            .overlay(Capsule().strokeBorder(phase.isLive ? Theme.tally : Theme.text, lineWidth: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(phase.isBusy)
        .accessibilityLabel(phase.isLive ? "Stop recording" : title)
    }

    private var busyTitle: String {
        if case .finishing = phase { return "Saving…" }
        return "Getting ready…"
    }

    private func blinkOn(at date: Date) -> Bool {
        reduceMotion || Int(date.timeIntervalSinceReferenceDate * 2) % 2 == 0
    }
}

/// Quiet text links along the foot of the panel.
private struct FooterLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The version next to the name. Click it to check for updates; when a
/// daily check finds one, it becomes an ink pill: "Update to 0.2.0".
struct UpdateBadge: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let version = updater.waitingVersion {
            Button("Update to \(version)", action: MenuPanel.closing { updater.checkForUpdates() })
                .buttonStyle(PillButtonStyle(kind: .primary))
        } else {
            Button("v\(updater.currentVersion)") { updater.checkForUpdates() }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .disabled(!updater.isEnabled)
                .help(updater.isEnabled ? "Check for updates" : "Dev builds don't update")
        }
    }
}

/// One muted line while the transcript is being written. Never orange:
/// only a live recording is orange.
struct TranscriptStatus: View {
    let text: String
    let phase: TranscriptionPhase
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if phase.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.text)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isFailed ? Theme.error : Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if isFailed {
                Spacer(minLength: 0)
                Button("Try again", action: retry)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
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

/// Screen, Window or Area, then what to record within it. Changes are
/// saved for the next take.
struct CapturePicker: View {
    @EnvironmentObject private var recorder: ScreenRecorder
    @State private var windows: [WindowCandidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ModeSwitch(selection: $recorder.choice.mode)

            switch recorder.choice.mode {
            case .screen:
                displayRow
            case .window:
                windowRow
            case .area:
                areaRow
            }
        }
    }

    @ViewBuilder
    private var displayRow: some View {
        if NSScreen.screens.count > 1 {
            ChoiceRow(label: "Display") {
                Picker("Display", selection: Binding(
                    get: { recorder.choice.displayID ?? CGMainDisplayID() },
                    set: { recorder.choice.displayID = $0 }
                )) {
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = screen.displayID {
                            Text(screen.localizedName).tag(id)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        } else {
            ChoiceRow(label: "Display") {
                Text(NSScreen.main?.localizedName ?? "Main display")
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
        }
    }

    private var windowRow: some View {
        ChoiceRow(label: "Window") {
            Picker("Window", selection: $recorder.choice.windowID) {
                Text("Choose a window").tag(UInt32?.none)
                ForEach(windows) { window in
                    Text(window.label).tag(UInt32?.some(window.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
        .task { windows = await recorder.pickableWindows() }
    }

    private var areaRow: some View {
        ChoiceRow(label: "Area") {
            if let area = recorder.choice.area {
                Text("\(Int(area.width)) × \(Int(area.height))")
                    .font(.system(size: 12, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.text)
            }
            Button(recorder.choice.area == nil ? "Choose area" : "Change area",
                   action: MenuPanel.closing { recorder.chooseArea() })
            .buttonStyle(PillButtonStyle(kind: .secondary))
        }
    }
}

/// A muted label on the left, the control on the right.
private struct ChoiceRow<Control: View>: View {
    let label: String
    let control: Control

    init(label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(label)
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: Theme.Space.sm)
            control
        }
        .font(.system(size: 12))
        .frame(minHeight: 24)
    }
}

/// Three ink segments with icons. The chosen one is a black pill, like a
/// primary button; the others are plain text.
private struct ModeSwitch: View {
    @Binding var selection: CaptureMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    selection = mode
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .labelStyle(.titleAndIcon)
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

private extension CaptureMode {
    var symbol: String {
        switch self {
        case .screen: return "display"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        }
    }
}

/// Mic, system sound, camera and iPhone screen, each naming what it records.
struct SourcesList: View {
    @EnvironmentObject private var recorder: ScreenRecorder
    @ObservedObject private var microphones = Microphones.shared
    @ObservedObject private var devices = CaptureDevices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SourceRow(symbol: "mic", title: "Microphone", isOn: $recorder.choice.includeMicrophone) {
                micMenu
            }
            if recorder.choice.includeMicrophone, let mic = activeMic, mic.dropsHeadphonesToCallQuality {
                Text("\(mic.name) switches to call quality while it records, so what you hear sounds muffled. Pick the Mac's mic to keep music quality.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            SourceRow(symbol: "speaker.wave.2", title: "System sound", isOn: $recorder.choice.includeSystemSound) {
                Text("What's playing on the Mac")
                    .foregroundStyle(Theme.textMuted)
            }
            SourceRow(symbol: "web.camera", title: "Camera", isOn: cameraOn) {
                cameraMenu
            }
            // iPhone screen over USB, from the device tracks work.
            SourcesRow(devices: devices)
        }
        .onAppear { microphones.refresh() }
    }

    private var activeMic: MicrophoneOption? { microphones.resolved(for: recorder.choice) }

    /// On means the bubble shows and camera.mov records. Switching on
    /// starts at Auto, which follows macOS (an iPhone on a stand wins).
    private var cameraOn: Binding<Bool> {
        Binding(get: { devices.cameraChoice != .off },
                set: { devices.cameraChoice = $0 ? .auto : .off })
    }

    private var cameraMenu: some View {
        Menu {
            Button {
                devices.cameraChoice = .auto
            } label: {
                if devices.cameraChoice == .auto {
                    Label("Automatic", systemImage: "checkmark")
                } else {
                    Text("Automatic")
                }
            }
            Divider()
            ForEach(devices.pickerCameras) { camera in
                Button {
                    devices.cameraChoice = .device(id: camera.id)
                } label: {
                    if devices.cameraChoice == .device(id: camera.id) {
                        Label(camera.name, systemImage: "checkmark")
                    } else {
                        Text(camera.name)
                    }
                }
            }
        } label: {
            Text(cameraDetail)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text)
        .disabled(devices.cameraChoice == .off || devices.cameras.isEmpty)
        .help("Which camera shows in the bubble")
    }

    private var cameraDetail: String {
        if devices.cameras.isEmpty { return "No camera found" }
        if devices.cameraChoice != .off, !devices.hasVideoAccess { return "Needs Camera access" }
        switch devices.cameraChoice {
        case .off: return devices.pickerCameras.first?.name ?? "Off"
        case .auto: return devices.cameraToRecord()?.localizedName ?? "Automatic"
        case .device: return devices.cameraLabel
        }
    }

    private var micMenu: some View {
        Menu {
            Button {
                recorder.choice.microphoneID = nil
            } label: {
                if recorder.choice.microphoneID == nil {
                    Label("Automatic", systemImage: "checkmark")
                } else {
                    Text("Automatic")
                }
            }
            Divider()
            ForEach(microphones.options) { option in
                Button {
                    recorder.choice.microphoneID = option.id
                } label: {
                    let name = option.dropsHeadphonesToCallQuality ? "\(option.name) (call quality)" : option.name
                    if recorder.choice.microphoneID == option.id {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Text(activeMic?.name ?? "No mic found")
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text)
        .disabled(!recorder.choice.includeMicrophone || microphones.options.isEmpty)
        .help("Which mic records your voice")
    }
}

/// Icon, name and what it records, then a switch. Faded when off.
private struct SourceRow<Detail: View>: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    let detail: Detail

    init(symbol: String, title: String, isOn: Binding<Bool>, @ViewBuilder detail: () -> Detail) {
        self.symbol = symbol
        self.title = title
        self._isOn = isOn
        self.detail = detail()
    }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isOn ? Theme.text : Theme.textMuted)
                detail
                    .font(.system(size: 11))
            }
            Spacer(minLength: Theme.Space.sm)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                // Ink, not the system switch, which goes grey whenever the
                // panel isn't the active window and makes "on" look off.
                .toggleStyle(InkSwitchStyle(label: title))
        }
        .frame(minHeight: 30)
    }
}

/// The newest take: a thumbnail, when it was made, then Review, Export and
/// Show in Finder. Export progress and the transcript line sit below.
struct LastTakeCard: View {
    let take: Take
    @ObservedObject var exports: ExportController
    @ObservedObject var transcriber: Transcriber
    let isBusy: Bool
    @State private var duration: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 10) {
                TakeThumbnail(take: take, duration: $duration)
                VStack(alignment: .leading, spacing: 2) {
                    Text(take.shortLabel())
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(detailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Button("Review take", action: MenuPanel.closing { EditorWindowController.shared.open(take) })
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(isBusy)
                    .help("Play it back, read the transcript and decide on the suggested cuts")
                ExportMenu(take: take, exports: exports, kind: .secondary)
                Spacer(minLength: 0)
                if case .exporting = exports.phase {
                    Button("Cancel") { exports.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                Button(action: MenuPanel.closing {
                    NSWorkspace.shared.activateFileViewerSelecting([take.screenURL])
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }

            if !exports.phase.status.isEmpty {
                HStack(spacing: Theme.Space.sm) {
                    if let ring = ringProgress {
                        ExportRing(progress: ring)
                    }
                    Text(exports.phase.status)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(exportFailed ? Theme.error : Theme.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .done = exports.phase {
                        Spacer(minLength: 0)
                        Button("Show", action: MenuPanel.closing { exports.revealExport() })
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
            }

            if let text = transcriber.phase.statusText {
                TranscriptStatus(text: text, phase: transcriber.phase) { transcriber.retry() }
            }
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        if let duration { parts.append(Timecode.short(from: duration)) }
        if transcriber.phase.statusText == nil,
           FileManager.default.fileExists(atPath: take.transcriptURL.path) {
            parts.append("Transcript ready")
        }
        return parts.isEmpty ? take.name : parts.joined(separator: " · ")
    }

    /// The ring fills while exporting and is solid once done.
    private var ringProgress: Double? {
        switch exports.phase {
        case let .exporting(_, progress): return progress
        case .done: return 1
        default: return nil
        }
    }

    private var exportFailed: Bool {
        if case .failed = exports.phase { return true }
        return false
    }
}

/// A frame from about a second in, with the take's length on it.
private struct TakeThumbnail: View {
    let take: Take
    @Binding var duration: Double?
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.canvas)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            if let duration {
                Text(Timecode.short(from: duration))
                    .font(.system(size: 9, weight: .medium, design: .monospaced).monospacedDigit())
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 3)
                    .background(Theme.text.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .frame(width: 72, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.line, lineWidth: 1))
        .task(id: take.folder) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        image = nil
        duration = nil
        let asset = AVURLAsset(url: take.screenURL)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        if seconds.isFinite, seconds > 0 { duration = seconds }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 288, height: 180)
        let at = CMTime(seconds: min(1, max(seconds / 2, 0)), preferredTimescale: 600)
        image = try? await generator.image(at: at).image
    }
}

/// The Export pill, black unless `kind` says otherwise, with one item
/// per preset. `keep` overrides the kept spans; nil uses the take's saved
/// edits.json.
struct ExportMenu: View {
    let take: Take
    var keep: [Range<Double>]? = nil
    @ObservedObject var exports: ExportController
    var kind: PillButtonStyle.Kind = .primary

    var body: some View {
        Menu("Export") {
            ForEach(ExportPreset.allCases) { preset in
                Button("\(preset.title) · \(preset.detail)") {
                    // Captions are built inside the export, from the
                    // timeline it renders; subtitle files follow once the
                    // video is done.
                    let brand = BrandStore.shared
                    exports.export(take, preset: preset, keep: keep,
                                   overlays: brand.overlays(),
                                   captionRingHex: brand.kit.ring.hex,
                                   cards: brand.cardMaker())
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(kind: kind))
        .fixedSize()
        .disabled(exports.phase.isBusy)
    }
}

/// Dashed ring filling to solid: dashed means not done yet, solid means
/// done. Ink for now; the builder's ring colour once it's linked to
/// Version One. Never orange, never green.
struct ExportRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.textMuted, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2.5]))
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(Theme.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// Closes the menu bar panel when one of its buttons opens a window, so
/// the window comes up in front instead of under the panel. MenuBarExtra
/// has no dismiss action for its window style, so the panel remembers its
/// own window (PanelWindowReader) and closes it; the next click on the
/// menu bar icon opens it again.
@MainActor
enum MenuPanel {
    fileprivate static weak var window: NSWindow?

    static func close() {
        window?.close()
    }

    /// `action`, run right after the panel closes.
    static func closing(_ action: @escaping () -> Void) -> () -> Void {
        {
            close()
            action()
        }
    }
}

/// Finds the window the panel is drawn in.
private struct PanelWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReaderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MenuPanel.window = window }
        }
    }
}
