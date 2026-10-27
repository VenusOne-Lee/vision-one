import Foundation

/// The builder's ring colour, picked on Version One. It is identity, never
/// UI state: it frames the camera bubble, draws the intro and outro rings
/// and colours keyword captions. Values match docs/DESIGN.md. Green is
/// allowed here because it is a Version One identity colour, even though
/// the app never uses it as an accent.
public enum RingColour: String, CaseIterable, Codable, Sendable, Identifiable {
    case blue, red, gold, green, purple, pink, black

    public var id: String { rawValue }

    public var hex: UInt32 {
        switch self {
        case .blue: return 0x1F3FBF
        case .red: return 0xD62B2B
        case .gold: return 0xE0A21B
        case .green: return 0x1E7D4F
        case .purple: return 0x7A3FBF
        case .pink: return 0xC2306E
        case .black: return 0x121212
        }
    }

    /// "#1F3FBF", for CSS in template cards.
    public var hexString: String { Self.css(hex) }

    public var title: String { rawValue.capitalized }

    static func css(_ hex: UInt32) -> String {
        String(format: "#%06X", hex & 0xFFFFFF)
    }
}

/// Fonts for the videos (not the app). Defaults are the two OFL families
/// from DESIGN.md. Any font installed on the Mac works; the card renderer
/// falls back to the system font when one is missing.
public struct BrandFonts: Codable, Equatable, Sendable {
    /// Names, titles, intro and outro.
    public var display: String
    /// Taglines and longer lines.
    public var body: String

    public init(display: String = "Bricolage Grotesque", body: String = "Source Serif 4") {
        self.display = display
        self.body = body
    }
}

/// An intro or outro card.
public struct BrandCard: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Seconds on screen. Kept between `durationRange` bounds.
    public var duration: Double

    public static let durationRange: ClosedRange<Double> = 1...8

    public init(enabled: Bool, duration: Double) {
        self.enabled = enabled
        self.duration = duration
    }

    /// The duration, kept inside `durationRange`.
    public var clampedDuration: Double {
        min(max(duration, Self.durationRange.lowerBound), Self.durationRange.upperBound)
    }
}

/// The logo in the corner of every frame. Position and size are what the
/// person dragged to, so it can sit anywhere, not just in four corners.
public struct BrandWatermark: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Centre of the logo, 0...1 from the top left of the frame.
    public var centerX: Double
    public var centerY: Double
    /// Width of the logo as a share of the frame's short edge.
    public var size: Double
    public var opacity: Double

    public init(enabled: Bool = false, centerX: Double = 0.94, centerY: Double = 0.9,
                size: Double = 0.09, opacity: Double = 0.9) {
        self.enabled = enabled
        self.centerX = centerX
        self.centerY = centerY
        self.size = size
        self.opacity = opacity
    }
}

/// The builder's look, applied to every video: ring colour, logo, fonts,
/// intro and outro. Saved as brand.json, with the logo file beside it, in
/// `~/Library/Application Support/Vision One/Brand/`. Plain files, so a
/// brand can be shared by copying the folder.
public struct BrandKit: Codable, Equatable, Sendable {
    public var version = 1
    /// Product or builder name, `{product}` in prompts and cards.
    public var name: String
    public var tagline: String
    /// Web address without the scheme, `{site}`.
    public var site: String
    /// Call to action for the outro, `{cta}`.
    public var cta: String
    public var ring: RingColour
    /// File name of the logo inside the brand folder, or nil for the
    /// name's first letter in the ring.
    public var logo: String?
    public var fonts: BrandFonts
    public var intro: BrandCard
    public var outro: BrandCard
    public var watermark: BrandWatermark
    /// Card colours. Light only, so paper is light and ink is dark.
    public var paperHex: UInt32
    public var inkHex: UInt32

    public init(name: String = "", tagline: String = "", site: String = "",
                cta: String = "Try it on Version One", ring: RingColour = .blue, logo: String? = nil,
                fonts: BrandFonts = BrandFonts(),
                intro: BrandCard = BrandCard(enabled: false, duration: 2.5),
                outro: BrandCard = BrandCard(enabled: false, duration: 4),
                watermark: BrandWatermark = BrandWatermark(),
                paperHex: UInt32 = 0xFFFFFF, inkHex: UInt32 = 0x121212) {
        self.name = name
        self.tagline = tagline
        self.site = site
        self.cta = cta
        self.ring = ring
        self.logo = logo
        self.fonts = fonts
        self.intro = intro
        self.outro = outro
        self.watermark = watermark
        self.paperHex = paperHex
        self.inkHex = inkHex
    }

    /// The letter shown in the ring when there is no logo.
    public var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "V"
    }

    /// The site as typed, minus any scheme and trailing slash.
    public var displaySite: String {
        var site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where site.lowercased().hasPrefix(scheme) {
            site.removeFirst(scheme.count)
        }
        while site.hasSuffix("/") { site.removeLast() }
        return site
    }

    // MARK: - Files

    public static let fileName = "brand.json"

    /// `~/Library/Application Support/Vision One/Brand/`.
    public static var standardFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Vision One/Brand", isDirectory: true)
    }

    /// Reads brand.json from `folder`. No file means the default brand;
    /// a broken file throws so it isn't silently replaced.
    public static func load(from folder: URL = standardFolder) throws -> BrandKit {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return BrandKit() }
        return try JSONDecoder().decode(BrandKit.self, from: Data(contentsOf: url))
    }

    public func save(to folder: URL = standardFolder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Where the logo file is, if there is one.
    public func logoURL(in folder: URL = standardFolder) -> URL? {
        guard let logo, !logo.isEmpty else { return nil }
        // Only a plain file name: brand.json can't point outside its folder.
        let name = (logo as NSString).lastPathComponent
        return folder.appendingPathComponent(name)
    }

    /// Copies a logo into the brand folder as logo.<ext> and points at it.
    public mutating func importLogo(from source: URL, into folder: URL = standardFolder,
                                    fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let name = "logo.\(ext)"
        let destination = folder.appendingPathComponent(name)
        if let old = logoURL(in: folder), fileManager.fileExists(atPath: old.path) {
            try fileManager.removeItem(at: old)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        logo = name
    }
}

// The decoder fills anything a newer or older brand.json is missing with
// the defaults, so adding a field never breaks someone's saved brand.
extension BrandKit {
    private enum CodingKeys: String, CodingKey {
        case version, name, tagline, site, cta, ring, logo, fonts, intro, outro, watermark, paperHex, inkHex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrandKit()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        tagline = try c.decodeIfPresent(String.self, forKey: .tagline) ?? d.tagline
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? d.site
        cta = try c.decodeIfPresent(String.self, forKey: .cta) ?? d.cta
        ring = (try? c.decodeIfPresent(RingColour.self, forKey: .ring)) ?? d.ring
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        fonts = try c.decodeIfPresent(BrandFonts.self, forKey: .fonts) ?? d.fonts
        intro = try c.decodeIfPresent(BrandCard.self, forKey: .intro) ?? d.intro
        outro = try c.decodeIfPresent(BrandCard.self, forKey: .outro) ?? d.outro
        watermark = try c.decodeIfPresent(BrandWatermark.self, forKey: .watermark) ?? d.watermark
        paperHex = try c.decodeIfPresent(UInt32.self, forKey: .paperHex) ?? d.paperHex
        inkHex = try c.decodeIfPresent(UInt32.self, forKey: .inkHex) ?? d.inkHex
    }
}
