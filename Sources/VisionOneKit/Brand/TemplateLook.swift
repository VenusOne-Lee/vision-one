import Foundation

/// The look half of a template: which brand cards it opens and closes
/// with, which shapes it exports and how each one is reframed, and the
/// caption style. What the video is for, its energy, length and part
/// prompts live with `Purpose` (the AI side); a look points at its
/// purpose by `purposeID`.
///
/// On disk a template is a folder, readable by people and by HyperFrames
/// tooling:
///
///     launch/
///       template.json   this manifest
///       intro.html      HyperFrames composition (optional)
///       outro.html      HyperFrames composition (optional)
///       prompts.md      part prompts (owned by the AI side)
public struct TemplateLook: Codable, Equatable, Sendable, Identifiable {
    /// One shape the template exports, with how it is fitted.
    public struct Format: Codable, Equatable, Sendable {
        public var format: VideoFormat
        public var reframe: ReframeMode
        /// Picked by the template (solid) or only suggested (dashed).
        public var suggested: Bool

        public init(_ format: VideoFormat, reframe: ReframeMode, suggested: Bool = false) {
            self.format = format
            self.reframe = reframe
            self.suggested = suggested
        }
    }

    /// Which card opens or closes the video.
    public enum Card: Codable, Equatable, Sendable {
        /// No card, whatever the brand kit says.
        case off
        /// The brand kit's own card (built in), if the kit has it on.
        case brand
        /// A HyperFrames HTML file in the template folder.
        case file(String)

        private enum CodingKeys: String, CodingKey { case type, file }

        public init(from decoder: Decoder) throws {
            // "none", "brand", or "intro.html" as a plain string.
            if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
                switch value {
                case "none", "off", "": self = .off
                case "brand": self = .brand
                default: self = .file(value)
                }
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let file = try c.decodeIfPresent(String.self, forKey: .file) {
                self = .file(file)
            } else {
                self = try c.decode(String.self, forKey: .type) == "none" ? .off : .brand
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .off: try c.encode("none")
            case .brand: try c.encode("brand")
            case let .file(name): try c.encode(name)
            }
        }
    }

    public var id: String
    public var title: String
    /// One line for the template card.
    public var summary: String
    /// `Purpose.id` on the AI side: launch, demo, short, tutorial,
    /// bugReport, update, talkingHead.
    public var purposeID: String
    public var intro: Card
    public var outro: Card
    public var formats: [Format]
    /// Caption style to start with, or nil for captions off.
    public var captionStyle: CaptionStyle?
    /// Allows the brand kit's corner logo. The kit decides whether it is
    /// on; a template can only leave it off (a bug report has no logo).
    public var watermark: Bool

    public init(id: String, title: String, summary: String, purposeID: String,
                intro: Card = .brand, outro: Card = .brand, formats: [Format],
                captionStyle: CaptionStyle? = nil, watermark: Bool = true) {
        self.id = id
        self.title = title
        self.summary = summary
        self.purposeID = purposeID
        self.intro = intro
        self.outro = outro
        self.formats = formats
        self.captionStyle = captionStyle
        self.watermark = watermark
    }

    /// The formats the template picks, not the suggestions.
    public var pickedFormats: [VideoFormat] { formats.filter { !$0.suggested }.map(\.format) }

    /// How the template fits a format; follow by default for shapes it
    /// doesn't list.
    public func reframe(for format: VideoFormat) -> ReframeMode {
        formats.first { $0.format == format }?.reframe ?? (format == .landscape ? .fit : .follow)
    }

    // MARK: - Files

    public static let manifestName = "template.json"

    /// Reads a template folder. The folder name is the id when the
    /// manifest leaves it out.
    public static func load(from folder: URL) throws -> TemplateLook {
        let data = try Data(contentsOf: folder.appendingPathComponent(manifestName))
        var look = try JSONDecoder().decode(TemplateLook.self, from: data)
        if look.id.isEmpty { look.id = folder.lastPathComponent }
        if look.purposeID.isEmpty { look.purposeID = look.id }
        if look.title.isEmpty { look.title = look.id }
        return look
    }

    public func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// Where a card file sits, kept inside the template folder: a
    /// manifest can't point a card at files elsewhere on the Mac.
    public static func cardURL(_ card: Card, in folder: URL) -> URL? {
        guard case let .file(name) = card else { return nil }
        let base = folder.standardizedFileURL
        let url = base.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), url.pathExtension.lowercased() == "html" else { return nil }
        return url
    }

    /// Every template folder (one with a template.json) inside `folder`.
    public static func loadAll(in folder: URL, fileManager: FileManager = .default) -> [TemplateLook] {
        let children = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .compactMap { try? load(from: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

// Decoding fills what an older or hand-written manifest leaves out.
extension TemplateLook {
    private enum CodingKeys: String, CodingKey {
        case id, title, summary, purposeID, intro, outro, formats, captionStyle, watermark
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        purposeID = try c.decodeIfPresent(String.self, forKey: .purposeID) ?? id
        intro = try c.decodeIfPresent(Card.self, forKey: .intro) ?? .brand
        outro = try c.decodeIfPresent(Card.self, forKey: .outro) ?? .brand
        formats = try c.decodeIfPresent([Format].self, forKey: .formats) ?? [Format(.landscape, reframe: .fit)]
        captionStyle = try c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle)
        watermark = try c.decodeIfPresent(Bool.self, forKey: .watermark) ?? true
    }
}

extension TemplateLook.Format {
    private enum CodingKeys: String, CodingKey { case format, reframe, suggested }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(VideoFormat.self, forKey: .format)
        reframe = try c.decodeIfPresent(ReframeMode.self, forKey: .reframe) ?? (format == .landscape ? .fit : .follow)
        suggested = try c.decodeIfPresent(Bool.self, forKey: .suggested) ?? false
    }
}

extension TemplateLook {
    /// The looks that ship with the app, one per v0.2 purpose, plus Blank.
    public static let builtIn: [TemplateLook] = [
        TemplateLook(id: "launch", title: "Launch video", summary: "Hook, context, payoff, brand",
                     purposeID: "launch",
                     formats: [Format(.landscape, reframe: .fit), Format(.vertical, reframe: .split),
                               Format(.square, reframe: .follow, suggested: true)],
                     captionStyle: .boldPop),
        TemplateLook(id: "demo", title: "Product demo", summary: "Zooms, cursor polish, chapter cards",
                     purposeID: "demo",
                     formats: [Format(.landscape, reframe: .fit), Format(.vertical, reframe: .follow, suggested: true)],
                     captionStyle: .subtitle),
        TemplateLook(id: "short", title: "Short", summary: "Best moment, hook first, vertical",
                     purposeID: "short", intro: .off,
                     formats: [Format(.vertical, reframe: .follow), Format(.square, reframe: .follow, suggested: true),
                               Format(.portrait, reframe: .follow, suggested: true)],
                     captionStyle: .wordByWord),
        TemplateLook(id: "tutorial", title: "Tutorial", summary: "Numbered steps and a written guide",
                     purposeID: "tutorial",
                     formats: [Format(.landscape, reframe: .fit)],
                     captionStyle: .subtitle),
        TemplateLook(id: "bugReport", title: "Bug report", summary: "No intro, no music, secrets blurred",
                     purposeID: "bugReport", intro: .off, outro: .off,
                     formats: [Format(.landscape, reframe: .fit)], watermark: false),
        TemplateLook(id: "update", title: "What's new", summary: "Changelog from your release notes",
                     purposeID: "update",
                     formats: [Format(.landscape, reframe: .fit), Format(.vertical, reframe: .follow)],
                     captionStyle: .keyword),
        TemplateLook(id: "talkingHead", title: "Talking head", summary: "Camera only, punch-ins",
                     purposeID: "talkingHead",
                     formats: [Format(.landscape, reframe: .fit), Format(.vertical, reframe: .follow, suggested: true)],
                     captionStyle: .keyword),
        TemplateLook(id: "blank", title: "Blank", summary: "Just your brand, nothing else",
                     purposeID: "blank",
                     formats: [Format(.landscape, reframe: .fit)]),
    ]

    public static func builtIn(id: String) -> TemplateLook? {
        builtIn.first { $0.id == id }
    }

    /// The built-in look for a purpose, for the "what is it for" picker.
    public static func builtIn(purposeID: String) -> TemplateLook? {
        builtIn.first { $0.purposeID == purposeID }
    }
}
