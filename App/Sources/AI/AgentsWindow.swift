import AppKit
import SwiftUI
import VisionOneKit

/// The agents for one take: what it's for and the Energy dial at the top,
/// then the Editor's ask bar, the Clipper and the Sharer. Everything they
/// make lands as a proposal: Editor cuts show dashed in the editor's
/// transcript and timeline, and posts are drafts until approved.
@MainActor
final class AgentsModel: ObservableObject {
    enum Run: Equatable {
        case idle
        case running(String)
        case done(String)
        case failed(String)
    }

    let take: Take
    @Published var plan: TakePlan { didSet { try? plan.write(for: take) } }
    @Published var ask = ""
    @Published private(set) var editorRun: Run = .idle
    @Published private(set) var clipperRun: Run = .idle
    @Published private(set) var sharerRun: Run = .idle
    @Published private(set) var clips: [ClipPick] = []
    @Published private(set) var share: SharePack?
    /// Prompt presets: Vision One's built-in ones, then yours.
    let presets = PresetLibrary.standard.all()
    @Published var presetName: String {
        didSet { UserDefaults.standard.set(presetName, forKey: "ai.preset") }
    }

    init(take: Take) {
        self.take = take
        let next = UserDefaults.standard.string(forKey: "ai.nextPurpose").flatMap(Purpose.named) ?? .demo
        plan = TakePlan.load(for: take) ?? TakePlan(purpose: next)
        share = SharePack.load(for: take)
        presetName = UserDefaults.standard.string(forKey: "ai.preset") ?? ""
    }

    var purpose: Purpose { plan.purpose }

    func choose(_ purpose: Purpose) {
        plan = TakePlan(purpose: purpose)
    }

    /// Prompts for this purpose with the chosen preset over them. The
    /// listing variables fill in once Version One sign-in lands.
    private var brief: AgentBrief {
        purpose.brief(preset: presets.first { $0.name == presetName })
    }

    func runEditor() {
        let goal = ask.isEmpty
            ? EditorAgent.Goal(targetSeconds: plan.targetSeconds)
            : EditorAgent.Goal.parse(ask)
        editorRun = .running(goal.targetSeconds.map { "Cutting to about \(Timecode.string(from: $0))…" } ?? "Reading every sentence…")
        let agent = EditorAgent(ladder: AIServices.shared.ladder())
        Task {
            do {
                let added = try await agent.run(on: take, brief: brief, goal: goal, energy: plan.energy)
                editorRun = .done(added.isEmpty
                    ? "Nothing more to cut."
                    : "\(added.count) suggested \(added.count == 1 ? "cut" : "cuts"), dashed in the editor until you accept.")
            } catch {
                editorRun = .failed(AgentsModel.message(for: error))
            }
        }
    }

    func runClipper() {
        clipperRun = .running("Scoring moments…")
        let agent = ClipperAgent(ladder: AIServices.shared.ladder())
        Task {
            do {
                let transcript = try Transcript.read(from: take.transcriptURL)
                let edits = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
                let format = purpose.formats.contains("vertical") ? "vertical" : purpose.formats.first ?? "vertical"
                let candidates = ClipperAgent.candidates(from: transcript.sentences(keeping: edits))
                guard !candidates.isEmpty else {
                    clipperRun = .done("This take is too short for clips of 15 seconds or more.")
                    return
                }
                clips = try await agent.pick(from: candidates, brief: brief, count: 3, format: format)
                clipperRun = .done(clips.isEmpty ? "No moment stands on its own yet." : "")
            } catch {
                clipperRun = .failed(AgentsModel.message(for: error))
            }
        }
    }

    func runSharer() {
        sharerRun = .running("Writing a title, chapters and posts…")
        let agent = SharerAgent(ladder: AIServices.shared.ladder())
        Task {
            do {
                let transcript = try Transcript.read(from: take.transcriptURL)
                let edits = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
                let pack = try await agent.draft(transcript: transcript, edits: edits, brief: brief,
                                                 launch: purpose.id == "launch" || purpose.id == "update")
                try pack.write(for: take)
                share = pack
                sharerRun = .done("")
            } catch {
                sharerRun = .failed(AgentsModel.message(for: error))
            }
        }
    }

    /// Opens the post in the network's own composer, after the user approves it.
    func post(_ post: SharePack.Post) {
        let (destination, url) = Self.composer(for: post)
        Task {
            do {
                try await SharerAgent.approvePost(post.text, to: destination, network: post.network,
                                                  gate: AIServices.shared.gate)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(post.text, forType: .string)
                NSWorkspace.shared.open(url)
            } catch {}
        }
    }

    /// The Version One launch draft goes on the clipboard and the site opens,
    /// after approval. Posting straight through Version One's MCP comes with
    /// the Vision One MCP server.
    func launchOnVersionOne() {
        guard let launch = share?.launch else { return }
        let text = [launch.name, launch.oneLine, launch.whoItsFor.map { "For: \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        Task {
            do {
                try await SharerAgent.approvePost(text, to: "versionone.co.za", network: "version one",
                                                  gate: AIServices.shared.gate)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                NSWorkspace.shared.open(URL(string: "https://versionone.co.za")!)
            } catch {}
        }
    }

    static func composer(for post: SharePack.Post) -> (String, URL) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let text = post.text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        switch post.network {
        case "x", "twitter":
            return ("x.com", URL(string: "https://x.com/intent/post?text=\(text)")!)
        case "linkedin":
            return ("linkedin.com", URL(string: "https://www.linkedin.com/feed/?shareActive=true&text=\(text)")!)
        case "whatsapp":
            return ("wa.me", URL(string: "https://wa.me/?text=\(text)")!)
        default:
            return ("versionone.co.za", URL(string: "https://versionone.co.za")!)
        }
    }

    static func message(for error: Error) -> String {
        switch error as? AIError {
        case .noProvider?:
            return "No AI is set up for this. Turn on Apple Intelligence, sign in with ChatGPT, or add a key in AI settings."
        case .notApproved?:
            return "Not sent. Nothing left your Mac."
        case let .unavailable(_, why)?:
            return why
        case .usageLimit?:
            return "Every rung that's set up has hit its usage limit. Try again later or add a key."
        case .tooLong?:
            return "This take is too long for the AI that's set up. Sign in with ChatGPT or add a key."
        case let .refused(_, why)?:
            return why.isEmpty ? "The model declined this one." : why
        case let .http(_, status, message)?:
            return "The AI service said \(status): \(message)"
        case let .badResponse(_, why)?:
            return "The reply didn't make sense (\(why)). Try again."
        case nil:
            if error is DecodingError { return "The reply didn't make sense. Try again." }
            return error.localizedDescription
        }
    }
}

struct AgentsView: View {
    @ObservedObject var model: AgentsModel
    @ObservedObject private var ai = AIServices.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                PurposePicker(selected: model.purpose.id) { model.choose($0) }
                if !model.presets.isEmpty {
                    Picker("Prompt preset", selection: $model.presetName) {
                        Text("None").tag("")
                        ForEach(model.presets) { Text($0.name).tag($0.name) }
                    }
                    .font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("ENERGY")
                    EnergyPicker(energy: $model.plan.energy)
                    Text(model.plan.energy.blurb).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                Divider().overlay(Theme.line)
                editor
                Divider().overlay(Theme.line)
                clipper
                Divider().overlay(Theme.line)
                sharer
                HStack {
                    Spacer()
                    Button("AI settings…") { AISettingsWindowController.shared.show() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(Theme.Space.lg)
        }
        .frame(minWidth: 380, idealWidth: 440, minHeight: 520)
        .background(Theme.paper)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light)
        .task { await ai.refresh() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel("EDITOR")
            Text("Suggests cuts beyond fillers and pauses. Say a length or what to cut.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            HStack(spacing: Theme.Space.sm) {
                TextField(model.plan.targetSeconds.map { "make it \(Int($0))s" } ?? "make it 60s, or cut the part about pricing",
                          text: $model.ask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.runEditor() }
                Button("Ask") { model.runEditor() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(isRunning(model.editorRun))
            }
            RunStatus(run: model.editorRun)
        }
    }

    private var clipper: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                sectionLabel("CLIPPER")
                Spacer()
                Button("Find clips") { model.runClipper() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(isRunning(model.clipperRun))
            }
            RunStatus(run: model.clipperRun)
            ForEach(model.clips, id: \.start) { clip in
                HStack(alignment: .top, spacing: Theme.Space.sm) {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: clip.format == "vertical" ? 12 : 20, height: clip.format == "vertical" ? 20 : 12)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip.title).font(.system(size: 13, weight: .semibold))
                        if let hook = clip.hook { Text(hook).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
                        Text("\(Timecode.string(from: clip.start)) → \(Timecode.string(from: clip.end)) · \(Int(clip.score * 100))%")
                            .font(.system(size: 11, design: .monospaced).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private var sharer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                sectionLabel("SHARER")
                Spacer()
                Button(model.share == nil ? "Write title and posts" : "Write again") { model.runSharer() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(isRunning(model.sharerRun))
            }
            RunStatus(run: model.sharerRun)
            if let share = model.share {
                CopyRow(label: "Title", text: share.title)
                if !share.description.isEmpty { CopyRow(label: "Description", text: share.description) }
                if !share.chapters.isEmpty { CopyRow(label: "Chapters", text: share.chapterText, mono: true) }
                ForEach(share.posts, id: \.network) { post in
                    VStack(alignment: .leading, spacing: 4) {
                        CopyRow(label: post.network.capitalized, text: post.text)
                        Button("Post to \(post.network.capitalized)…") { model.post(post) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
                if share.launch != nil {
                    Button("Launch on Version One…") { model.launchOnVersionOne() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).tracking(0.6).foregroundStyle(Theme.textMuted)
    }

    private func isRunning(_ run: AgentsModel.Run) -> Bool {
        if case .running = run { return true }
        return false
    }
}

struct RunStatus: View {
    let run: AgentsModel.Run

    var body: some View {
        switch run {
        case .idle:
            EmptyView()
        case let .running(text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        case let .done(text):
            if !text.isEmpty { Text(text).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
        case let .failed(text):
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CopyRow: View {
    let label: String
    let text: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            Text(text)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Dashed: a draft until you post or copy it.
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.textMuted, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

/// "What are you making?" as cards, two to a row.
struct PurposePicker: View {
    let selected: String
    let choose: (Purpose) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("What are you making?").font(.system(size: 17, weight: .light))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.sm)], spacing: Theme.Space.sm) {
                ForEach(Purpose.all) { purpose in
                    Button { choose(purpose) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(purpose.title).font(.system(size: 13, weight: .semibold))
                            Text(summary(purpose)).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(purpose.id == selected ? Theme.selectionSoft : Theme.paper,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .strokeBorder(purpose.id == selected ? Theme.selection : Theme.line,
                                          lineWidth: purpose.id == selected ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(purpose.blurb)
                }
            }
        }
    }

    private func summary(_ p: Purpose) -> String {
        let length: String
        if let range = p.targetSeconds {
            length = range.upperBound < 60 ? "under \(Int(range.upperBound + 1)) s"
                : "\(Timecode.string(from: range.lowerBound))–\(Timecode.string(from: range.upperBound))"
        } else {
            length = "any length"
        }
        return "\(p.energy.title) · \(length)"
    }
}

/// Calm / Lively / Viral as a three-way pill.
struct EnergyPicker: View {
    @Binding var energy: Energy

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Energy.allCases) { option in
                Button { energy = option } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(option == energy ? Theme.paper : Theme.text)
                        .background(option == energy ? Theme.text : Theme.paper)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.text, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Energy")
    }
}

/// One agents window, following whichever take the editor has open.
@MainActor
final class AgentsWindowController {
    static let shared = AgentsWindowController()
    private var window: NSWindow?

    func show(for take: Take) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 720),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.sharingType = .none
            window.setFrameAutosaveName("VisionOneAgents")
            window.center()
            self.window = window
        }
        window?.title = "Agents · \(take.name.replacingOccurrences(of: "Vision One ", with: ""))"
        window?.contentViewController = NSHostingController(rootView: AgentsView(model: AgentsModel(take: take)))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
