import AppKit
import SwiftUI
import VisionOneKit

/// The panel that drops down from the menu bar. Ink on paper; the only
/// orange is the record dot and, while live, the button border.
struct MenuContent: View {
    @EnvironmentObject private var recorder: ScreenRecorder
    @ObservedObject private var exports = ExportController.shared
    @ObservedObject private var transcriber = Transcriber.shared

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
                ErrorAlert(message: message) { recorder.openSetup() }
            }

            if let text = transcriber.phase.statusText {
                TranscriptStatus(text: text, phase: transcriber.phase) { transcriber.retry() }
            }

            if let take = recorder.lastTake, !recorder.phase.isLive {
                ExportRow(take: take, exports: exports)
            }

            Divider().overlay(Theme.line)

            HStack {
                Button("Edit last take") { EditorWindowController.shared.openLatest() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(recorder.phase.isLive || recorder.phase.isBusy)
                Button("Show recordings") { recorder.revealRecordings() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Button("Brand") { BrandWindowController.shared.show() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
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

/// Exports the last take, with the cuts saved in its edits.json.
struct ExportRow: View {
    let take: Take
    @ObservedObject var exports: ExportController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                ExportMenu(take: take, exports: exports)

                Spacer()

                switch exports.phase {
                case .exporting:
                    Button("Cancel") { exports.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                case .done:
                    Button("Show") { exports.revealExport() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                default:
                    EmptyView()
                }
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
                }
            }
        }
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

/// The black Export pill with one item per preset. `keep` overrides the
/// kept spans; nil uses the take's saved edits.json.
struct ExportMenu: View {
    let take: Take
    var keep: [Range<Double>]? = nil
    @ObservedObject var exports: ExportController

    var body: some View {
        Menu("Export") {
            ForEach(ExportPreset.allCases) { preset in
                Button("\(preset.title) · \(preset.detail)") {
                    let brand = BrandStore.shared
                    CaptionExport.writeFiles(for: take, preset: preset)
                    exports.export(take, preset: preset, keep: keep,
                                   overlays: CaptionExport.overlays(for: take, ringHex: brand.kit.ring.hex) + brand.overlays(),
                                   cards: brand.cardMaker())
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(kind: .primary))
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
