import AppKit
import SwiftUI
import VisionOneKit

/// The right of Home: who's on camera, what records, and the one round
/// record button. Screen, camera and mic are menus, saved for the next take
/// the same way the menu bar panel saves them.
struct HomeRecordPane: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    @ObservedObject private var devices = CaptureDevices.shared
    @ObservedObject private var microphones = Microphones.shared
    @State private var windows: [WindowCandidate] = []
    @State private var countdown = Countdown.shared.length

    var body: some View {
        VStack(spacing: 14) {
            HomeCameraRing(isOn: devices.cameraChoice != .off)
            VStack(spacing: 6) {
                screenRow
                cameraRow
                micRow
            }
            HomeRecordButton(phase: recorder.phase) {
                Task { await recorder.toggle() }
            }
            .padding(.top, 4)
            countdownPicker
            status
        }
        .frame(maxWidth: .infinity)
        .task { await refreshWindows() }
        .onAppear { microphones.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refreshWindows() }
        }
    }

    /// Only with Screen Recording access, so opening Home never triggers
    /// the system prompt by itself.
    private func refreshWindows() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        windows = await recorder.pickableWindows()
    }

    // MARK: Status under the button

    @ViewBuilder
    private var status: some View {
        VStack(spacing: 4) {
            if recorder.phase.isLive {
                // Orange only says "live".
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    HStack(spacing: 6) {
                        if recorder.isPaused {
                            Circle().strokeBorder(Theme.text, lineWidth: 1.5).frame(width: 8, height: 8)
                        } else {
                            Circle().fill(Theme.tally).frame(width: 8, height: 8)
                        }
                        Text("\(recorder.isPaused ? "Paused" : "Recording") \(Self.clock(recorder.recordedTime(at: context.date)))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced).monospacedDigit())
                            .foregroundStyle(Theme.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            } else if case let .failed(message) = recorder.phase {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if recorder.isCountingDown {
                Text("Get ready…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else if recorder.phase == .preparing {
                Text("Starting…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else if recorder.phase == .finishing {
                Text("Saving the take…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Text("⌘⇧R record · ⌥⇧P pause")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
        }
    }

    /// Off, 3 s or 5 s before recording starts, saved for every record
    /// button and ⌘⇧R.
    private var countdownPicker: some View {
        Menu {
            ForEach(CountdownLength.allCases, id: \.self) { length in
                Button {
                    countdown = length
                    Countdown.shared.length = length
                } label: {
                    checked(length == .off ? "No countdown" : "\(length.rawValue) second countdown", countdown == length)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Countdown").foregroundStyle(Theme.textMuted)
                Text(countdown.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        .help("How long to count down before recording")
    }

    /// "04:12", or "1:04:12" past an hour, in tabular mono.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: Rows

    private var screenRow: some View {
        HomeDeviceRow(label: "Screen") {
            Menu {
                Button { recorder.choice.mode = .screen } label: { checked("Whole screen", recorder.choice.mode == .screen) }
                Menu("A window") {
                    if windows.isEmpty {
                        Text("No windows to record")
                    }
                    ForEach(windows) { window in
                        Button {
                            recorder.choice.windowID = window.id
                            recorder.choice.mode = .window
                        } label: {
                            checked(window.label, recorder.choice.mode == .window && recorder.choice.windowID == window.id)
                        }
                    }
                }
                Button {
                    recorder.chooseArea()
                } label: {
                    checked(recorder.choice.area == nil ? "An area…" : "Change area…", recorder.choice.mode == .area)
                }
            } label: {
                Text(screenName).lineLimit(1).truncationMode(.middle)
            }
        }
        .help("What the take records")
    }

    private var screenName: String {
        let choice = recorder.choice
        switch choice.mode {
        case .screen:
            return "Whole screen"
        case .window:
            guard let id = choice.windowID else { return "Pick a window" }
            return windows.first { $0.id == id }?.appName ?? "Window"
        case .area:
            guard let area = choice.area else { return "Choose an area" }
            return "Area · \(Int(area.width)) × \(Int(area.height))"
        }
    }

    private var cameraRow: some View {
        HomeDeviceRow(label: "Camera") {
            Menu {
                Button { devices.cameraChoice = .off } label: { checked("Off", devices.cameraChoice == .off) }
                Button { devices.cameraChoice = .auto } label: { checked("Automatic", devices.cameraChoice == .auto) }
                if !devices.pickerCameras.isEmpty { Divider() }
                ForEach(devices.pickerCameras) { camera in
                    Button {
                        devices.cameraChoice = .device(id: camera.id)
                    } label: {
                        checked(camera.name, devices.cameraChoice == .device(id: camera.id))
                    }
                }
            } label: {
                Text(cameraName).lineLimit(1).truncationMode(.tail)
            }
        }
        .help("Which camera shows in the bubble")
    }

    private var cameraName: String {
        if devices.cameraChoice == .off { return "Off" }
        if devices.cameras.isEmpty { return "No camera found" }
        if !devices.hasVideoAccess { return "Needs Camera access" }
        switch devices.cameraChoice {
        case .off: return "Off"
        case .auto: return devices.cameraToRecord()?.localizedName ?? "Automatic"
        case .device: return devices.cameraLabel
        }
    }

    private var micRow: some View {
        HomeDeviceRow(label: "Mic") {
            Menu {
                Button {
                    recorder.choice.includeMicrophone = false
                } label: {
                    checked("Off", !recorder.choice.includeMicrophone)
                }
                Button {
                    recorder.choice.includeMicrophone = true
                    recorder.choice.microphoneID = nil
                } label: {
                    checked("Automatic", recorder.choice.includeMicrophone && recorder.choice.microphoneID == nil)
                }
                if !microphones.options.isEmpty { Divider() }
                ForEach(microphones.options) { option in
                    Button {
                        recorder.choice.includeMicrophone = true
                        recorder.choice.microphoneID = option.id
                    } label: {
                        let name = option.dropsHeadphonesToCallQuality ? "\(option.name) (call quality)" : option.name
                        checked(name, recorder.choice.includeMicrophone && recorder.choice.microphoneID == option.id)
                    }
                }
            } label: {
                Text(micName).lineLimit(1).truncationMode(.tail)
            }
        }
        .help("Which mic records your voice")
    }

    private var micName: String {
        guard recorder.choice.includeMicrophone else { return "Off" }
        return microphones.resolved(for: recorder.choice)?.name ?? "No mic found"
    }

    /// A menu item with a tick when it's the current choice.
    @ViewBuilder
    private func checked(_ title: String, _ isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// White row, line border, radius 8: muted label left, bold choice right.
private struct HomeDeviceRow<Control: View>: View {
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
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.visible)
                .fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Where the camera will be. The live preview lives in the floating
/// bubble, so here it's the dashed ring (not recording yet) with the
/// builder's initials, or a camera glyph when the camera is on.
private struct HomeCameraRing: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(Theme.paper)
            Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 5, dash: [9, 6]))
            if isOn || Self.initials.isEmpty {
                Image(systemName: "web.camera")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Theme.text)
            } else {
                Text(Self.initials)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(width: 120, height: 120)
        .accessibilityElement()
        .accessibilityLabel(isOn ? "Camera on" : "Camera off")
    }

    /// "Lee Ntshudisane" → "LN".
    static let initials: String = {
        NSFullUserName()
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }()
}

/// 72 pt white circle with a 5 pt ink border and an orange dot, the record
/// affordance. While live the border turns orange and the dot becomes an
/// ink stop square.
struct HomeRecordButton: View {
    let phase: RecordingPhase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.paper)
                Circle().strokeBorder(phase.isLive ? Theme.tally : Theme.text, lineWidth: 5)
                if phase.isLive {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.text)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .fill(Theme.tally)
                        .frame(width: 30, height: 30)
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
            .opacity(phase.isBusy ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(phase.isBusy)
        .help(phase.isLive ? "Stop recording (⌘⇧R)" : "Start recording (⌘⇧R)")
        .accessibilityLabel(phase.isLive ? "Stop recording" : "Start recording")
    }
}
