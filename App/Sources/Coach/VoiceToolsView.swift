import AppKit
import SwiftUI
import VisionOneKit

/// AI voice tools for one take: optional ElevenLabs tools, each a single
/// dashed proposal with before and after, and Undo always there.
struct VoiceToolsView: View {
    @ObservedObject var model: VoiceToolsModel
    @ObservedObject private var coach = CoachServices.shared
    @State private var askingConsent = false
    @State private var consented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                if !coach.elevenLabsReady {
                    Notice(.info, lead: "These tools use your ElevenLabs account", detail: coach.elevenLabsNote,
                           action: ("Open Settings", { SettingsWindowController.shared.show(.ai) }))
                }
                isolator
                wordFix
                dub
                if let problem = model.problem { Notice(.error, lead: problem) }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $askingConsent) { consentSheet }
        .onDisappear { model.stopPreview() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voice tools").textStyle(.title)
            Text("Uses your ElevenLabs account. Vision One stays free. Each tool asks before sending audio, and only your mic track is ever sent, never your screen.")
                .textStyle(.body).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Voice isolator

    private var isolator: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Clean a noisy take").textStyle(.headline)
                Spacer()
                Tag("ElevenLabs voice isolator")
            }
            Text("Takes out wind, hooters and the room, and keeps your voice. Try the free Remove noise on this Mac first; use this when that isn't enough.")
                .textStyle(.body).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let clean = model.edits.cleanVoice {
                HStack(spacing: Theme.Space.sm) {
                    Button("▶ Before") { model.preview(cleaned: false) }.buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    Button("▶ After") { model.preview(cleaned: true) }.buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    Spacer()
                    StateChip(clean.kept ? .accepted : .proposed, clean.kept ? "Kept · used in export" : "Suggested")
                    if !clean.kept {
                        Button("Keep") { model.keepCleanVoice() }.buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                    }
                    Button("Undo") { model.undoCleanVoice() }.buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                }
            } else {
                Button(model.work == .cleaning ? "Cleaning…" : "Clean the voice (\(Timecode.short(from: model.micSeconds)))") {
                    model.cleanVoice()
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                .disabled(!coach.elevenLabsReady || model.work != .idle)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
        .statusOutline(model.edits.cleanVoice?.kept == true ? .accepted : .proposed, cornerRadius: Theme.Radius.lg,
                       lineWidth: Theme.Stroke.hairline)
    }

    // MARK: Fix a word

    private var wordFix: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Fix a word in my voice").textStyle(.headline)
                Spacer()
                StateChip(.proposed, "AI voice · labelled")
            }
            Text("Re-says one wrong word in your own cloned voice. The transcript marks every AI-spoken word, and the export can say so. If you can re-record, Redo one sentence is better.")
                .textStyle(.body).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !model.hasClone {
                Button(model.work == .cloning ? "Making your voice…" : "Make my voice clone…") { askingConsent = true }
                    .buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    .disabled(!coach.elevenLabsReady || model.work != .idle)
            } else {
                TextField("Find the word", text: $model.search).textFieldStyle(.ink)
                if model.candidates.isEmpty {
                    Text(model.search.isEmpty ? "Type the word that came out wrong." : "No word like that in this take.")
                        .textStyle(.caption).foregroundStyle(Theme.textMuted)
                }
                FlowRow(model.candidates) { word in
                    Button("\(word.text) · \(Timecode.short(from: word.start))") { model.selectedWordID = word.id }
                        .buttonStyle(PillButtonStyle(kind: model.selectedWordID == word.id ? .primary : .secondary, size: .small))
                }
                if let word = model.selectedWord {
                    HStack(spacing: Theme.Space.sm) {
                        Text("“\(word.text)” →").textStyle(.body)
                        TextField("What it should say", text: $model.replacement).textFieldStyle(.ink)
                            .onSubmit { model.fixWord() }
                        Button(model.work == .fixing ? "Saying it…" : "Say it in my voice") { model.fixWord() }
                            .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                            .disabled(model.replacement.trimmingCharacters(in: .whitespaces).isEmpty || model.work != .idle)
                    }
                }
            }
            ForEach(model.edits.fixes) { fix in
                HStack(spacing: Theme.Space.sm) {
                    Text("“\(fix.original)” → “\(fix.replacement)”").font(Font(Theme.transcriptFont(size: 14) as CTFont))
                    Mono(Timecode.short(from: fix.start), small: true).foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("▶ Hear it") { model.hearFix(fix) }.buttonStyle(PillButtonStyle(kind: .secondary, size: .small))
                    StateChip(fix.kept ? .accepted : .proposed, fix.kept ? "Kept" : "Suggested")
                    if !fix.kept {
                        Button("Use it") { model.keepFix(fix) }.buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                    }
                    Button("Undo") { model.undoFix(fix) }.buttonStyle(PillButtonStyle(kind: .quiet, size: .small))
                }
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
        .statusOutline(.proposed, cornerRadius: Theme.Radius.lg, lineWidth: Theme.Stroke.hairline)
    }

    private var dub: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dub to another language").textStyle(.headline)
                Text("isiZulu, Afrikaans, Sesotho and more, in your voice. Coming later.").textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            StateChip(.proposed, "Later")
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.paper))
        .statusOutline(.proposed, cornerRadius: Theme.Radius.lg, lineWidth: Theme.Stroke.hairline)
        .opacity(0.7)
    }

    // MARK: Consent

    private var consentSheet: some View {
        SheetScaffold("Make a clone of your voice?",
                      subtitle: "ElevenLabs makes it from up to three of your takes (about two minutes each). It's stored on your ElevenLabs account, and you can delete it there any time.",
                      primary: "Make my voice clone", primaryDisabled: !consented,
                      onPrimary: {
                          askingConsent = false
                          model.makeClone()
                      },
                      onCancel: { askingConsent = false }) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Toggle("This is my own voice, and I agree to an AI copy of it being made for fixing words in my videos.", isOn: $consented)
                    .toggleStyle(.checkbox)
                    .textStyle(.body)
                Text("Vision One only uses it when you ask for a fix, and labels every word it says.")
                    .textStyle(.caption).foregroundStyle(Theme.textMuted)
            }
        }
        .frame(width: 460, height: 300)
    }
}

/// Wraps small buttons onto as many rows as they need.
struct FlowRow<Data: RandomAccessCollection, Item: View>: View where Data.Element: Identifiable {
    let data: Data
    let item: (Data.Element) -> Item

    init(_ data: Data, @ViewBuilder item: @escaping (Data.Element) -> Item) {
        self.data = data
        self.item = item
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(data) { element in item(element) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

@MainActor
final class VoiceToolsWindowController: NSObject {
    static let shared = VoiceToolsWindowController()
    private var window: NSWindow?
    private var model: VoiceToolsModel?

    /// Opens the tools for the take open in the editor, or the newest take.
    func show(for take: Take? = nil) {
        guard let take = take ?? TakeLibrary.standard.takes().first else { return }
        if model?.take.folder != take.folder {
            let model = VoiceToolsModel(take: take)
            self.model = model
            if let window {
                window.contentViewController = NSHostingController(rootView: VoiceToolsView(model: model))
            }
        }
        if window == nil, let model {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: VoiceToolsView(model: model))
            window.appearance = NSAppearance(named: .aqua)
            window.setFrameAutosaveName("VisionOneVoiceToolsWindow")
            window.sharingType = .none
            window.center()
            self.window = window
        }
        window?.title = "Voice Tools · \(take.folder.lastPathComponent)"
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        Task { await coach.refresh() }
    }

    private var coach: CoachServices { CoachServices.shared }
}
