import Foundation

/// A style the person chose to keep: the profile plus which traits they
/// ticked. Saved as style.json beside template.json, so a copied template
/// is an ordinary template folder with extra numbers for the Editor,
/// zooms and music.
public struct CopiedStyle: Codable, Equatable, Sendable {
    public static let fileName = "style.json"

    public var profile: StyleProfile
    public var copying: Set<StyleTraitID>
    public var createdAt: Date

    public init(profile: StyleProfile, copying: Set<StyleTraitID>? = nil, createdAt: Date = Date()) {
        self.profile = profile
        self.copying = copying ?? Set(profile.traits.filter(\.copiedByDefault).map(\.id))
        self.createdAt = createdAt
    }

    public func copies(_ trait: StyleTraitID) -> Bool { copying.contains(trait) }

    /// The purpose the template points at; its prompts drive the agents.
    public var purpose: Purpose {
        Purpose.named(profile.purposeID) ?? .launch
    }

    /// The look half of the template. Anything not copied comes from the
    /// built-in look for the same purpose.
    public func look(id: String, title: String) -> TemplateLook {
        let base = TemplateLook.builtIn(purposeID: profile.purposeID) ?? TemplateLook.builtIn(id: "blank")!
        var look = base
        look.id = id
        look.title = title
        look.summary = summary
        look.purposeID = profile.purposeID
        if copies(.intro) { look.intro = profile.intro == nil ? .off : .brand }
        if copies(.outro) { look.outro = profile.outro == nil ? .off : .brand }
        if copies(.shape) {
            let main = profile.format
            var formats = [TemplateLook.Format(main, reframe: main == .landscape ? .fit : .follow)]
            if main != .landscape { formats.append(TemplateLook.Format(.landscape, reframe: .fit, suggested: true)) }
            if main != .vertical { formats.append(TemplateLook.Format(.vertical, reframe: .follow, suggested: true)) }
            look.formats = formats
        }
        if copies(.captions) { look.captionStyle = profile.captions?.style }
        return look
    }

    /// One line for the template card: "Fast cuts, bold pop captions, vertical".
    public var summary: String {
        var parts: [String] = []
        if copies(.cuts) { parts.append("\(profile.cuts.pace.title.lowercased()) cuts") }
        if copies(.captions) {
            parts.append(profile.captions.map { "\($0.style.title.lowercased()) captions" } ?? "no captions")
        }
        if copies(.framing) { parts.append(profile.framing.kind.title.lowercased()) }
        if copies(.shape) { parts.append(profile.format.title.lowercased()) }
        guard let first = parts.first else { return "Copied from \(profile.source)" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    /// Energy for the Editor, zooms, sound and captions: the source's when
    /// cut rhythm is copied, otherwise the purpose's.
    public var energy: Energy { copies(.cuts) ? profile.energy : purpose.energy }

    /// Length the Editor aims for.
    public var targetSeconds: ClosedRange<Double>? { copies(.shape) ? profile.targetSeconds : purpose.targetSeconds }

    /// Zooms a minute for the zoom planner, or nil to follow the Energy.
    public var zoomsPerMinute: Double? { copies(.zooms) ? max(profile.framing.punchInsPerMinute, 0) : nil }

    /// Pause lengths for the cleanup pass, matching the source's rhythm.
    public var keptPause: Double? {
        guard copies(.cuts) else { return nil }
        switch profile.cuts.pace {
        case .rapid: return 0.15
        case .fast: return 0.25
        case .steady: return 0.4
        case .slow: return 0.6
        }
    }

    /// Whether the template wants a music bed, or nil to leave it to Energy.
    public var wantsMusic: Bool? { copies(.music) ? profile.music != nil : nil }

    /// Their colours for cards, only when ticked.
    public var cardColours: [String]? { copies(.colours) ? profile.palette.map(\.hex) : nil }

    // MARK: - Files

    public static func load(from folder: URL) -> CopiedStyle? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CopiedStyle.self, from: data)
    }

    public func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// The person's own templates, one folder each.
public enum UserTemplates {
    public static var standardFolder: URL {
        BrandKit.standardFolder.deletingLastPathComponent().appendingPathComponent("Templates", isDirectory: true)
    }

    /// Writes template.json and style.json into a new folder named after
    /// the title, and returns the folder.
    @discardableResult
    public static func save(_ style: CopiedStyle, title: String, in root: URL = standardFolder,
                            fileManager: FileManager = .default) throws -> URL {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleanTitle.isEmpty ? style.profile.suggestedTitle : cleanTitle
        let id = uniqueID(for: name, in: root, fileManager: fileManager)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try style.look(id: id, title: name).save(to: folder)
        try style.save(to: folder)
        return folder
    }

    /// "Fast talking head" → "fast-talking-head", "-2" and so on when that
    /// folder or a built-in id is taken.
    public static func uniqueID(for title: String, in root: URL, fileManager: FileManager = .default) -> String {
        var slug = ""
        for ch in title.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                slug.append(ch)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "style" }
        slug = String(slug.prefix(40))
        let builtIn = Set(TemplateLook.builtIn.map { $0.id.lowercased() })
        var candidate = slug
        var n = 2
        while builtIn.contains(candidate) || fileManager.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(slug)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Every saved template with its copied style, if it has one.
    public static func loadAll(in root: URL = standardFolder) -> [(look: TemplateLook, style: CopiedStyle?, folder: URL)] {
        TemplateLook.loadAll(in: root).map { look in
            let folder = root.appendingPathComponent(look.id, isDirectory: true)
            return (look, CopiedStyle.load(from: folder), folder)
        }
    }
}
