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
        plan = TakePlan.load(for: take) ?? TakePlan.next() ?? TakePlan(purpose: .demo)
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
                // The on-device finder's windows first; plain sentence windows if it found none.
                var candidates = ClipFinder().candidates(transcript: transcript, edits: edits).map(ClipCandidate.init)
                if candidates.isEmpty {
                    candidates = ClipperAgent.candidates(from: transcript.sentences(keeping: edits))
                }
                guard !candidates.isEmpty else {
                    clipperRun = .done("This take is too short for clips of 15 seconds or more.")
                    return
                }
                clips = try await agent.pick(from: candidates, brief: brief, count: 3, format: format)
                // Into clips.json, where the editor's Clips tab shows them dashed.
                var list = try ClipList.load(from: take.clipsURL)
                let added = list.propose(clips.map(\.clip), sourceDuration: transcript.duration)
                try list.write(to: take.clipsURL)
                if clips.isEmpty {
                    clipperRun = .done("No moment stands on its own yet.")
                } else {
                    clipperRun = .done(added.isEmpty ? "These are already in the Clips tab."
                                       : "Added \(added.count) to the Clips tab, dashed until you keep them.")
                }
            } catch {
                clipperRun = .failed(AgentsModel.message(for: error))
            }
        }
    }

    /// `note` is what you told the Sharer to do differently on an
    /// approval card; `launch` asks for the Version One fields whatever
    /// the take is for.
    func runSharer(note: String? = nil, launch: Bool = false) {
        sharerRun = .running(note == nil ? "Writing a title, chapters and posts…" : "Writing it again…")
        let agent = SharerAgent(ladder: AIServices.shared.ladder())
        var brief = brief
        if let note, !note.isEmpty {
            let post = brief.parts["post"].map { $0 + "\n" } ?? ""
            brief.parts["post"] = post + "The builder read the last draft and asked: \(note)"
        }
        let product = BrandStore.shared.kit.name
        let wantsLaunch = launch || purpose.id == "launch" || purpose.id == "update"
        Task {
            do {
                let transcript = try Transcript.read(from: take.transcriptURL)
                let edits = try EditList.load(from: take.editsURL, sourceDuration: transcript.duration)
                let pack = try await agent.draft(transcript: transcript, edits: edits, brief: brief,
                                                 product: product.isEmpty ? nil : product,
                                                 launch: wantsLaunch)
                try pack.write(for: take)
                share = pack
                sharerRun = .done("")
            } catch let reason as SharerAgent.TooLittleSaid {
                sharerRun = .done(reason.recoveryMessage)
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
        guard let text = share?.launch?.postText else { return }
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
        guard let target = ShareTarget(network: post.network) else {
            return ("versionone.co.za", URL(string: "https://versionone.co.za")!)
        }
        return (target.destination, target.composer(text: post.text))
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
