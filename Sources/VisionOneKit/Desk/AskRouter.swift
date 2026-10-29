import Foundation

/// The composer's slash commands, with the one line the menu shows.
public struct SlashCommand: Equatable, Sendable {
    public var name: String
    public var summary: String
    /// Runs agents (a plan) rather than opening something in the window.
    public var runsAgents: Bool

    public static let all: [SlashCommand] = [
        SlashCommand(name: "record", summary: "Record your screen, camera and mic", runsAgents: false),
        SlashCommand(name: "cut", summary: "Cut ums, pauses and retakes", runsAgents: true),
        SlashCommand(name: "captions", summary: "Add or restyle captions", runsAgents: false),
        SlashCommand(name: "clips", summary: "Make short clips for Reels and TikTok", runsAgents: true),
        SlashCommand(name: "music", summary: "Pick music for this video", runsAgents: false),
        SlashCommand(name: "sound", summary: "Open sound in full mode", runsAgents: false),
        SlashCommand(name: "edit", summary: "Open the editor in full mode", runsAgents: false),
        SlashCommand(name: "style", summary: "Copy the style of another video", runsAgents: false),
        SlashCommand(name: "copy", summary: "Try changes in a copy, keep the main cut safe", runsAgents: true),
        SlashCommand(name: "review", summary: "Show every change as a before and after", runsAgents: false),
        SlashCommand(name: "script", summary: "Write a script from your releases and issues", runsAgents: true),
        SlashCommand(name: "share", summary: "Export, copy a link or post", runsAgents: true),
    ]

    /// Commands starting with what's typed after "/", for the menu.
    public static func matching(_ typed: String) -> [SlashCommand] {
        let prefix = typed.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        return prefix.isEmpty ? all : all.filter { $0.name.hasPrefix(prefix) }
    }
}

/// What the composer should do with an ask.
public enum AskRoute: Equatable, Sendable {
    /// Agents to run, in order (shown first under "Plan first").
    case plan(DeskPlan)
    /// A command the window handles itself: "record", "captions", "edit"…
    case open(String)
}

/// Turns what the user typed into the Producer's plan. Plain rules on the
/// Mac, so it works with no AI set up; the Editor reads the ask itself for
/// anything finer ("cut the part about pricing").
public enum AskRouter {
    public static func route(_ ask: String) -> AskRoute {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            let name = parts.first?.lowercased() ?? ""
            let rest = parts.count > 1 ? parts[1] : ""
            switch name {
            case "cut": return .plan(DeskPlan(steps: [edit(rest.isEmpty ? nil : rest)]))
            case "clips": return .plan(DeskPlan(steps: [clips(count(in: rest) ?? 3)]))
            case "share", "post": return .plan(DeskPlan(steps: [share(launch: mentionsLaunch(rest))]))
            case "script": return .plan(DeskPlan(steps: [script]))
            case "copy":
                guard case var .plan(plan) = route(rest.isEmpty ? "/cut" : rest) else { return route(rest) }
                plan.inCopy = true
                return .plan(plan)
            default: return .open(name)
            }
        }
        // Exact navigation requests should never accidentally start an edit job.
        let navigation: [String: String] = [
            "record": "record", "start recording": "record",
            "open editor": "edit", "open sound": "sound", "open mixer": "sound",
            "add captions": "captions", "show captions": "captions",
            "review changes": "review", "show changes": "review",
            "copy a style": "style", "choose music": "music"
        ]
        if let command = navigation[text.lowercased().trimmingCharacters(in: .punctuationCharacters)] {
            return .open(command)
        }
        return .plan(plan(for: text))
    }

    static func plan(for text: String) -> DeskPlan {
        let lower = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        var steps: [DeskPlan.Step] = []
        if has(["script", "talking points", "what to say", "what's new", "changelog", "release notes"]) {
            steps.append(script)
        }
        let wantsClips = has(["clip", "reel", "tiktok", "short for", "shorts"])
        let wantsPost = has(["post", "share", "title", "caption for", "launch", "linkedin", "tweet", "publish",
                             "description", "chapters"])
        let wantsEdit = has(["cut", "shorter", "tighten", "trim", "make it", "under ", "remove", "drop", "seconds",
                             "minute", " um", "pause", "faster", "edit", "clean"])
        if wantsEdit || (steps.isEmpty && !wantsClips && !wantsPost) {
            steps.append(edit(text))
        }
        if wantsClips { steps.append(clips(count(in: lower) ?? 3)) }
        if wantsPost { steps.append(share(launch: mentionsLaunch(lower))) }
        return DeskPlan(steps: steps, inCopy: has(["in a copy", "try a version", "another version", "alternative cut"]))
    }

    static func edit(_ ask: String?) -> DeskPlan.Step {
        DeskPlan.Step(agent: .editor, title: ask.map { "Edit: \($0)" } ?? "Cut ums, pauses and retakes",
                      action: .edit(ask: ask))
    }

    static func clips(_ count: Int) -> DeskPlan.Step {
        DeskPlan.Step(agent: .clipper, title: "Make \(count) \(count == 1 ? "clip" : "clips")", action: .clips(count: count))
    }

    static func share(launch: Bool) -> DeskPlan.Step {
        DeskPlan.Step(agent: .sharer, title: launch ? "Write the launch post" : "Write a title and posts",
                      action: .share(launch: launch))
    }

    static let script = DeskPlan.Step(agent: .producer, title: "Draft a script from what's new", action: .script)

    static func mentionsLaunch(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("launch") || lower.contains("version one")
    }

    /// "3 clips", "five clips": the number just before "clip".
    static func count(in text: String) -> Int? {
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6]
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (i, token) in tokens.enumerated() where token.hasPrefix("clip") && i > 0 {
            let before = tokens[i - 1]
            if let n = Int(before) ?? words[before] { return min(max(n, 1), 10) }
        }
        if let n = tokens.compactMap({ Int($0) }).first, tokens.count <= 2 { return min(max(n, 1), 10) }
        return nil
    }
}
