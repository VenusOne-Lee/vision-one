import Foundation

/// "Pick what it's for": the answer sets the Energy, the target length and
/// the agents' prompts. How it looks (cards, captions, reframing) is the
/// brand kit's `TemplateLook`, matched by `id`.
public struct Purpose: Codable, Equatable, Identifiable, Sendable {
    /// Shared with TemplateLook.purposeID: launch, demo, short, tutorial,
    /// bugReport, update, talkingHead.
    public var id: String
    public var title: String
    /// One line on the picker card.
    public var blurb: String
    public var energy: Energy
    /// Seconds the Editor aims for, or nil to only clean up.
    public var targetSeconds: ClosedRange<Double>?
    /// Format ids suggested first: "landscape", "vertical", "square".
    public var formats: [String]
    /// Default prompt per part, keyed like AgentBrief.parts.
    public var prompts: [String: String]

    public init(id: String, title: String, blurb: String, energy: Energy, targetSeconds: ClosedRange<Double>?,
                formats: [String], prompts: [String: String]) {
        self.id = id
        self.title = title
        self.blurb = blurb
        self.energy = energy
        self.targetSeconds = targetSeconds
        self.formats = formats
        self.prompts = prompts
    }

    public func brief(houseStyle: String? = nil, overrides: [String: String] = [:]) -> AgentBrief {
        AgentBrief(purpose: title, parts: prompts.merging(overrides) { $1 }, houseStyle: houseStyle)
    }

    public static func named(_ id: String) -> Purpose? { all.first { $0.id == id } }

    public static let all: [Purpose] = [launch, demo, short, tutorial, bugReport, update, talkingHead]

    public static let launch = Purpose(
        id: "launch", title: "Launch", blurb: "Show what you built, for Version One and socials.",
        energy: .lively, targetSeconds: 45...90, formats: ["landscape", "vertical", "square"],
        prompts: [
            "hook": "Open with the problem {product} solves for {audience}, in one sentence.",
            "body": "Keep the moments that show {product} working. Cut setup, apologies and repeats.",
            "outro": "End on where to try it: {site}. {cta}",
            "title": "A plain title that says what {product} does. No clickbait, under 60 characters.",
            "post": "A launch post in the builder's voice: what it is, who it's for, the link. South African English.",
            "chapters": "Short chapter names, three to five words each.",
            "clip": "Moments that make sense alone and show the product doing something.",
            "thumbnail": "The product's main screen with three or four big words.",
        ])

    public static let demo = Purpose(
        id: "demo", title: "Product demo", blurb: "Walk someone through how it works.",
        energy: .lively, targetSeconds: 60...180, formats: ["landscape"],
        prompts: [
            "hook": "Say what the viewer will be able to do by the end.",
            "body": "Keep every step of the walkthrough. Cut dead ends, waiting and repeats.",
            "outro": "Recap in one line and point to {site}.",
            "title": "How to do the main thing with {product}.",
            "post": "A short post inviting {audience} to watch the demo.",
            "chapters": "One chapter per step.",
            "clip": "One step that works on its own.",
            "thumbnail": "The screen at the step that matters most.",
        ])

    public static let short = Purpose(
        id: "short", title: "Short", blurb: "Under a minute, vertical, made to be watched to the end.",
        energy: .viral, targetSeconds: 20...59, formats: ["vertical"],
        prompts: [
            "hook": "The first three seconds must make someone stop scrolling.",
            "body": "Only the best moments. Cut anything that doesn't move it forward.",
            "outro": "End fast. {cta}",
            "title": "A punchy title under 50 characters.",
            "post": "A caption for TikTok, Reels and Shorts, with up to three hashtags.",
            "chapters": "",
            "clip": "The single strongest moment.",
            "thumbnail": "One bold frame, two or three words.",
        ])

    public static let tutorial = Purpose(
        id: "tutorial", title: "Tutorial", blurb: "Teach one thing, step by step.",
        energy: .calm, targetSeconds: nil, formats: ["landscape"],
        prompts: [
            "hook": "Say what this teaches and who it's for.",
            "body": "Keep every step and explanation. Only cut mistakes, waiting and repeats.",
            "outro": "Recap the steps.",
            "title": "How to … , in plain words.",
            "post": "A post saying what people will learn.",
            "chapters": "One chapter per step, numbered.",
            "clip": "A tip that works on its own.",
            "thumbnail": "The finished result.",
        ])

    public static let bugReport = Purpose(
        id: "bugReport", title: "Bug report", blurb: "Show what went wrong, for a teammate.",
        energy: .calm, targetSeconds: nil, formats: ["landscape"],
        prompts: [
            "hook": "",
            "body": "Keep the steps to reproduce and the error. Cut nothing that shows what happened on screen.",
            "outro": "",
            "title": "What broke, where: a bug title a developer would search for.",
            "post": "A bug report: steps to reproduce, what happened, what should happen.",
            "chapters": "",
            "clip": "",
            "thumbnail": "",
        ])

    public static let update = Purpose(
        id: "update", title: "Update", blurb: "What's new since last time.",
        energy: .lively, targetSeconds: 30...120, formats: ["landscape", "vertical"],
        prompts: [
            "hook": "Lead with the biggest change.",
            "body": "One short part per change. Cut repeats and long setup.",
            "outro": "Say what's next and point to {site}.",
            "title": "{product}: what's new.",
            "post": "A changelog-style post: what's new, in short lines.",
            "chapters": "One chapter per change.",
            "clip": "The most visual change.",
            "thumbnail": "The new feature on screen.",
        ])

    public static let talkingHead = Purpose(
        id: "talkingHead", title: "Talking head", blurb: "You on camera, sharing a thought.",
        energy: .lively, targetSeconds: 30...120, formats: ["vertical", "landscape"],
        prompts: [
            "hook": "Open on the most surprising sentence.",
            "body": "Keep the argument. Cut tangents, fillers and false starts.",
            "outro": "End on the takeaway.",
            "title": "The idea in under 60 characters.",
            "post": "A post with the main idea in the first line.",
            "chapters": "",
            "clip": "A sentence or two that stands alone as a quote.",
            "thumbnail": "Your face and three words.",
        ])
}

/// What an agent is working toward, with every prompt already resolved
/// (prompt presets and {variables} are filled in before this). Keys:
/// hook, title, body, outro, post, chapters, thumbnail, clip.
public struct AgentBrief: Equatable, Sendable {
    public var purpose: String
    public var parts: [String: String]
    public var houseStyle: String?

    public init(purpose: String, parts: [String: String] = [:], houseStyle: String? = nil) {
        self.purpose = purpose
        self.parts = parts
        self.houseStyle = houseStyle
    }

    /// House style plus the named parts, for a request's instructions.
    public func instructions(_ lead: String, parts names: [String]) -> String {
        var lines = [lead, "This video is a \(purpose)."]
        if let houseStyle, !houseStyle.isEmpty { lines.append("House style: \(houseStyle)") }
        for name in names {
            if let text = parts[name], !text.isEmpty { lines.append("\(name.capitalized): \(text)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// The choices made for one take: what it's for and the dial. Saved as
/// plan.json in the take folder so every feature reads the same answer.
public struct TakePlan: Codable, Equatable, Sendable {
    public var purposeID: String
    public var energy: Energy
    public var targetSeconds: Double?

    public init(purposeID: String, energy: Energy, targetSeconds: Double? = nil) {
        self.purposeID = purposeID
        self.energy = energy
        self.targetSeconds = targetSeconds
    }

    public init(purpose: Purpose) {
        self.init(purposeID: purpose.id, energy: purpose.energy, targetSeconds: purpose.targetSeconds?.upperBound)
    }

    public var purpose: Purpose { Purpose.named(purposeID) ?? .demo }

    public static func load(for take: Take) -> TakePlan? {
        guard let data = try? Data(contentsOf: take.planURL) else { return nil }
        return try? JSONDecoder().decode(TakePlan.self, from: data)
    }

    public func write(for take: Take) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: take.planURL, options: .atomic)
    }
}

extension Take {
    /// What it's for and the Energy dial (TakePlan).
    public var planURL: URL { folder.appendingPathComponent("plan.json") }
    /// The Sharer's drafts (SharePack).
    public var shareURL: URL { folder.appendingPathComponent("share.json") }
}
