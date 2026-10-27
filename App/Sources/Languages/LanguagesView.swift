import AppKit
import SwiftUI
import VisionOneKit

/// Every South African language in one list: what's ready, how good it
/// will be, and one button each.
struct LanguagesView: View {
    @ObservedObject var model: LanguagesModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    spokenSection
                    captionsSection
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(Theme.line)
            status
        }
        .background(Theme.paper)
        .frame(minWidth: 480, minHeight: 480)
        .themed()
    }

    // MARK: Spoken

    private var spokenSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Spoken in").textStyle(.label).foregroundStyle(Theme.textMuted)
            HStack(spacing: Theme.Space.sm) {
                Text(model.spoken.name).textStyle(.headline).foregroundStyle(Theme.text)
                QualityChip(quality: model.spoken.support.transcribe.quality)
            }
            Text(model.spoken.support.transcribe.note.isEmpty ? model.spoken.support.transcribe.engine
                 : "\(model.spoken.support.transcribe.engine) · \(model.spoken.support.transcribe.note)")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: Captions

    private var captionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Captions in").textStyle(.label).foregroundStyle(Theme.textMuted)
                Spacer()
                Picker("Burn into the video", selection: $model.captionLanguage) {
                    Text("\(model.spoken.name), as spoken").tag(SALanguage?.none)
                    ForEach(model.translated) { language in
                        Text(language.name).tag(SALanguage?.some(language))
                    }
                }
                .fixedSize()
                .help("The language drawn on the video. Every other ready language is written as its own .srt and .vtt next to the export.")
            }
            VStack(spacing: Theme.Space.xs) {
                ForEach(model.targets) { language in
                    LanguageRow(language: language, ready: model.translated.contains(language),
                                running: model.work.translatingLanguage == language,
                                progress: model.work.translatingProgress,
                                busy: model.work.isBusy,
                                translate: { model.translate(language) },
                                remove: { model.remove(language) })
                }
            }
            Text("Translated sentence by sentence by your AI rung, so cuts and caption styles work the same. Names like your product stay as they are.")
                .textStyle(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Status

    private var status: some View {
        HStack(spacing: Theme.Space.sm) {
            switch model.work {
            case .idle:
                Text("Captions use your AI rung, which asks before sending.")
                    .textStyle(.caption).foregroundStyle(Theme.textMuted)
            case let .translating(language, progress):
                ProgressView(value: progress).tint(Theme.text).frame(width: 120)
                Text("Translating into \(language.name)…").textStyle(.caption).foregroundStyle(Theme.text)
            case let .failed(message):
                Text(message).textStyle(.caption).foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            case let .done(message):
                Text(message).textStyle(.caption).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.work.isBusy {
                Button("Stop") { model.cancel() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
    }
}

extension LanguagesModel.Work {
    var translatingLanguage: SALanguage? {
        if case let .translating(language, _) = self { return language }
        return nil
    }

    var translatingProgress: Double {
        if case let .translating(_, progress) = self { return progress }
        return 0
    }
}

/// One language: its names, how good the translation will be, and what
/// to do. Dashed while it's only on offer, solid once it's ready.
private struct LanguageRow: View {
    let language: SALanguage
    let ready: Bool
    let running: Bool
    let progress: Double
    let busy: Bool
    let translate: () -> Void
    let remove: () -> Void

    private var ability: LanguageAbility { language.support.translate }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.xs) {
                    Text(language.name).textStyle(.bodyStrong).foregroundStyle(Theme.text)
                    if language.ownName != language.name {
                        Text(language.ownName).textStyle(.caption).foregroundStyle(Theme.textMuted)
                    }
                }
                if ready, ability.quality.wantsSpeakerCheck {
                    Text("Ask a \(language.name) speaker to read it before you post")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            QualityChip(quality: ability.quality)
            if running {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small).tint(Theme.text)
            } else if ready {
                Menu {
                    Button("Translate again", action: translate)
                    Button("Remove \(language.name) captions", role: .destructive, action: remove)
                } label: {
                    Text("Ready").textStyle(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy)
            } else {
                Button("Translate", action: translate)
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    .disabled(busy)
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.paper))
        .statusOutline(ready ? .accepted : .proposed, cornerRadius: Theme.Radius.md,
                       lineWidth: ready ? Theme.Stroke.ring : Theme.Stroke.hairline)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(language.name), translation \(ability.quality.title.lowercased())\(ready ? ", ready" : "")")
    }
}

/// How good a language job will be: filled, half-filled, dashed or faint,
/// with the word beside it so colour is never the only signal.
struct QualityChip: View {
    let quality: LanguageQuality

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                switch quality {
                case .good:
                    Circle().fill(Theme.text)
                case .fair:
                    Circle().strokeBorder(Theme.text, lineWidth: 1.3)
                    Circle().trim(from: 0.25, to: 0.75).fill(Theme.text).rotationEffect(.degrees(0))
                case .rough:
                    Circle().strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.3, dash: Theme.Stroke.dashSmall))
                case .none:
                    Circle().strokeBorder(Theme.textFaint, lineWidth: 1.3)
                }
            }
            .frame(width: 9, height: 9)
            Text(quality.title)
                .textStyle(.caption)
                .foregroundStyle(quality == .none ? Theme.textFaint : Theme.textMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quality: \(quality.title)")
    }
}

/// The Languages window, opened from the editor.
@MainActor
final class LanguagesWindowController {
    static let shared = LanguagesWindowController()
    private var window: NSWindow?
    private var model: LanguagesModel?

    func show(for take: Take) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("VisionOneLanguages")
            window.center()
            self.window = window
        }
        if model?.take.folder != take.folder, model?.work.isBusy != true {
            let model = LanguagesModel(take: take)
            self.model = model
            window?.contentViewController = NSHostingController(rootView: LanguagesView(model: model))
        } else {
            model?.refresh()
        }
        window?.title = "Languages · \(take.name.replacingOccurrences(of: "Vision One ", with: ""))"
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
