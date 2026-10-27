import Foundation

/// How fast a video cuts, from its middle shot length.
public enum StylePace: String, Codable, CaseIterable, Sendable {
    /// A shot every 6 s or longer.
    case slow
    /// 3 to 6 s.
    case steady
    /// 1.5 to 3 s.
    case fast
    /// Under 1.5 s.
    case rapid

    public var title: String {
        switch self {
        case .slow: return "Slow"
        case .steady: return "Steady"
        case .fast: return "Fast"
        case .rapid: return "Rapid"
        }
    }

    public static func from(medianShot: Double) -> StylePace {
        switch medianShot {
        case ..<1.5: return .rapid
        case ..<3: return .fast
        case ..<6: return .steady
        default: return .slow
        }
    }
}

/// What fills the frame most of the time.
public enum StyleFramingKind: String, Codable, CaseIterable, Sendable {
    /// A face fills a good part of the frame.
    case talkingHead
    /// A small face in a corner over a screen.
    case cameraBubble
    /// Mostly screen or b-roll, few faces.
    case screen

    public var title: String {
        switch self {
        case .talkingHead: return "Talking head"
        case .cameraBubble: return "Screen with camera bubble"
        case .screen: return "Screen first"
        }
    }
}

public enum StyleCaptionPlacement: String, Codable, Sendable {
    case middle, bottom
}

public enum StyleHookKind: String, Codable, Sendable {
    /// Someone talks within the first second.
    case talksFirst
    /// Words on screen before anyone talks.
    case textFirst
    /// A cut inside the first two seconds.
    case quickCut
    /// None of those: a slower opening.
    case slowOpen

    public var title: String {
        switch self {
        case .talksFirst: return "Talks straight away"
        case .textFirst: return "Opens on words"
        case .quickCut: return "Cuts in the first 2 s"
        case .slowOpen: return "Slow open"
        }
    }
}

/// The style of a video, as numbers. Saved as style.json in a template
/// folder. Nothing in it can rebuild the source video.
public struct StyleProfile: Codable, Equatable, Sendable {
    public struct Cuts: Codable, Equatable, Sendable {
        public var times: [Double]
        public var perMinute: Double
        public var medianShot: Double
        public var averageShot: Double
        public var pace: StylePace
    }

    public struct Captions: Codable, Equatable, Sendable {
        public var style: CaptionStyle
        /// Middle number of words on screen at once.
        public var wordsPerCaption: Double
        public var uppercase: Bool
        public var placement: StyleCaptionPlacement
        /// Share of read frames with a caption.
        public var coverage: Double
        public var changesPerMinute: Double
    }

    public struct Framing: Codable, Equatable, Sendable {
        public var kind: StyleFramingKind
        /// Share of read frames with a face.
        public var faceShare: Double
        /// Middle face size, as a share of the frame's area.
        public var faceArea: Double
        /// Sudden face growth between shots, a minute.
        public var punchInsPerMinute: Double
    }

    public struct Swatch: Codable, Equatable, Sendable {
        public var hex: String
        /// Share of the picture, 0...1.
        public var share: Double
    }

    public struct Music: Codable, Equatable, Sendable {
        /// Share of the video with music.
        public var share: Double
        /// Beats a minute, when a steady beat was found.
        public var bpm: Double?
        /// How far under the voice the music sits, in dB, when both were heard.
        public var underVoiceDB: Double?
    }

    public struct Hook: Codable, Equatable, Sendable {
        public var kind: StyleHookKind
        public var speechStart: Double?
        public var firstCut: Double?
    }

    /// Where it came from, for the card: a file name or a site, never a link.
    public var source: String
    public var duration: Double
    public var width: Double
    public var height: Double
    public var format: VideoFormat
    public var cuts: Cuts
    /// Nil when there were no captions.
    public var captions: Captions?
    public var framing: Framing
    public var palette: [Swatch]
    /// Weighted luminance of the picture, 0 dark to 1 light.
    public var brightness: Double
    /// Seconds of the opening card, or nil for none.
    public var intro: Double?
    /// Seconds of the closing card, or nil for none.
    public var outro: Double?
    /// Nil when there was no music.
    public var music: Music?
    /// Share of the video with someone talking.
    public var speechShare: Double
    public var hook: Hook
    public var energy: Energy
    /// The closest `Purpose.id`.
    public var purposeID: String
    /// How sure the scanner is, per trait, 0...1.
    public var confidence: [String: Double]
}

/// One line on the result screen, ticked to copy it.
public enum StyleTraitID: String, Codable, CaseIterable, Sendable {
    case cuts, captions, framing, zooms, shape, intro, outro, music, colours

    public var title: String {
        switch self {
        case .cuts: return "Cut rhythm"
        case .captions: return "Captions"
        case .framing: return "Framing"
        case .zooms: return "Zooms"
        case .shape: return "Shape and length"
        case .intro: return "Intro"
        case .outro: return "Outro"
        case .music: return "Music"
        case .colours: return "Their colours"
        }
    }
}

public struct StyleTrait: Equatable, Identifiable, Sendable {
    public var id: StyleTraitID
    /// "Fast: a cut every 1.2 s".
    public var value: String
    /// "49 cuts a minute".
    public var detail: String
    public var confidence: Double
    /// Ticked when the result opens. Colours start unticked: the brand
    /// kit's colours win unless the person asks for theirs.
    public var copiedByDefault: Bool
}

extension StyleProfile {
    public var minutes: Double { max(duration, 1) / 60 }

    /// The result screen's lines, in order.
    public var traits: [StyleTrait] {
        func c(_ id: StyleTraitID) -> Double { confidence[id.rawValue] ?? 0.5 }
        var list: [StyleTrait] = []

        list.append(StyleTrait(
            id: .cuts, value: "\(cuts.pace.title): a cut every \(Self.seconds(cuts.medianShot))",
            detail: "\(Int(cuts.perMinute.rounded())) cuts a minute", confidence: c(.cuts), copiedByDefault: true))

        if let captions {
            let words = captions.wordsPerCaption <= 3 ? "1 to 3 words" : "about \(Int(captions.wordsPerCaption.rounded())) words"
            list.append(StyleTrait(
                id: .captions, value: "\(captions.style.title), \(words)",
                detail: [captions.uppercase ? "Upper case" : "Normal case",
                         captions.placement == .middle ? "middle of the frame" : "bottom of the frame"].joined(separator: ", "),
                confidence: c(.captions), copiedByDefault: true))
        } else {
            list.append(StyleTrait(id: .captions, value: "No captions", detail: "No words changing on screen",
                                   confidence: c(.captions), copiedByDefault: true))
        }

        list.append(StyleTrait(
            id: .framing, value: framing.kind.title,
            detail: framing.faceShare > 0
                ? "Face in \(Self.percent(framing.faceShare)) of frames, \(Self.percent(framing.faceArea)) of the picture"
                : "No faces found",
            confidence: c(.framing), copiedByDefault: true))

        list.append(StyleTrait(
            id: .zooms,
            value: framing.punchInsPerMinute >= 0.5 ? "Punch-ins, \(Int(framing.punchInsPerMinute.rounded())) a minute" : "Few zooms",
            detail: framing.punchInsPerMinute >= 0.5 ? "The face grows between shots" : "The framing stays put",
            confidence: c(.zooms), copiedByDefault: true))

        list.append(StyleTrait(
            id: .shape, value: "\(format.title), \(Self.seconds(duration, digits: 0))",
            detail: "Target \(Self.seconds(targetSeconds.lowerBound, digits: 0)) to \(Self.seconds(targetSeconds.upperBound, digits: 0))",
            confidence: c(.shape), copiedByDefault: true))

        list.append(StyleTrait(
            id: .intro, value: intro.map { "Card, \(Self.seconds($0))" } ?? "None",
            detail: intro == nil ? hook.kind.title : "Words, nobody talking, at the start",
            confidence: c(.intro), copiedByDefault: true))

        list.append(StyleTrait(
            id: .outro, value: outro.map { "Card, \(Self.seconds($0))" } ?? "None",
            detail: outro == nil ? "Ends on the last shot" : "Words, nobody talking, at the end",
            confidence: c(.outro), copiedByDefault: true))

        if let music {
            var value = "Music bed"
            if let bpm = music.bpm { value += ", about \(Int(bpm.rounded())) bpm" }
            let detail = music.underVoiceDB.map { "About \(Int($0.rounded())) dB under the voice" } ?? "Plays through \(Self.percent(music.share))"
            list.append(StyleTrait(id: .music, value: value, detail: detail, confidence: c(.music), copiedByDefault: true))
        } else if c(.music) <= 0.2 {
            // No sound was heard at all, so there's nothing to copy.
            list.append(StyleTrait(id: .music, value: "Sound not heard", detail: "Music is left to the Energy dial",
                                   confidence: c(.music), copiedByDefault: false))
        } else {
            list.append(StyleTrait(id: .music, value: "No music", detail: "Voice only",
                                   confidence: c(.music), copiedByDefault: true))
        }

        if !palette.isEmpty {
            list.append(StyleTrait(
                id: .colours, value: palette.prefix(4).map(\.hex).joined(separator: " "),
                detail: "Your brand kit draws the cards unless you tick this",
                confidence: c(.colours), copiedByDefault: false))
        }
        return list
    }

    /// The length to aim for: the source's length, give or take a fifth,
    /// on 5 s steps, never under 10 s.
    public var targetSeconds: ClosedRange<Double> {
        let low = max(10, (duration * 0.8 / 5).rounded(.down) * 5)
        let high = max(low + 5, (duration * 1.2 / 5).rounded(.up) * 5)
        return low...high
    }

    /// A plain name to start from: "Fast talking head short".
    public var suggestedTitle: String {
        let who: String
        switch framing.kind {
        case .talkingHead: who = "talking head"
        case .cameraBubble: who = "screen and camera"
        case .screen: who = "screen"
        }
        let what: String
        switch purposeID {
        case "short": what = "short"
        case "tutorial": what = "tutorial"
        case "demo": what = "demo"
        case "launch": what = "launch"
        default: what = "video"
        }
        let name = "\(cuts.pace.title) \(who) \(what)"
        return name.replacingOccurrences(of: "talking head video", with: "talking head")
    }

    /// The numbers as short lines, for the AI to name the template. No
    /// frames, words or sound from the video go in.
    public var summaryLines: String {
        var lines = [
            "Shape: \(format.title), \(Int(duration.rounded())) s",
            "Cuts: \(cuts.pace.rawValue), \(Int(cuts.perMinute.rounded())) a minute, middle shot \(Self.seconds(cuts.medianShot))",
            "Framing: \(framing.kind.title), face in \(Self.percent(framing.faceShare)) of frames",
            "Punch-ins a minute: \(Int(framing.punchInsPerMinute.rounded()))",
            "Opening: \(hook.kind.title)",
            "Energy: \(energy.title)",
        ]
        if let captions {
            lines.append("Captions: \(captions.style.title), \(Int(captions.wordsPerCaption.rounded())) words, \(captions.uppercase ? "upper case" : "normal case")")
        } else {
            lines.append("Captions: none")
        }
        if let music {
            lines.append("Music: yes\(music.bpm.map { ", \(Int($0.rounded())) bpm" } ?? "")")
        } else {
            lines.append("Music: none")
        }
        lines.append("Intro card: \(intro == nil ? "none" : "yes"); outro card: \(outro == nil ? "none" : "yes")")
        lines.append("Picture: \(brightness < 0.35 ? "dark" : brightness > 0.65 ? "light" : "mid")")
        return lines.joined(separator: "\n")
    }

    static func seconds(_ value: Double, digits: Int = 1) -> String {
        if digits == 0 || value >= 10 { return "\(Int(value.rounded())) s" }
        return String(format: "%.1f s", value)
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }
}

extension VideoFormat {
    /// The shape whose aspect is closest to `width` by `height`.
    public static func nearest(width: Double, height: Double) -> VideoFormat {
        guard width > 0, height > 0 else { return .landscape }
        let aspect = log(width / height)
        return allCases.min { abs(log($0.aspect) - aspect) < abs(log($1.aspect) - aspect) } ?? .landscape
    }
}
