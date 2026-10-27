import Foundation

/// The image sizes a thumbnail is saved in.
public enum ThumbnailSize: String, Codable, CaseIterable, Sendable, Identifiable {
    /// YouTube's thumbnail: 16:9, JPEG, under 2 MB.
    case youtube
    /// Shorts and Reels cover: 9:16.
    case cover
    /// Version One listing, LinkedIn: 1:1.
    case square

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .cover: return "Cover"
        case .square: return "Square"
        }
    }

    public var pixels: (width: Int, height: Int) {
        switch self {
        case .youtube: return (1280, 720)
        case .cover: return (1080, 1920)
        case .square: return (1080, 1080)
        }
    }

    public var aspect: Double { Double(pixels.width) / Double(pixels.height) }

    /// JPEG for YouTube (it caps uploads at 2 MB), PNG for the rest.
    public var fileExtension: String { self == .youtube ? "jpg" : "png" }

    public var sizeLimitBytes: Int? { self == .youtube ? 2_000_000 : nil }

    /// Part of the frame social apps never crop or cover, as a
    /// normalized rect. Reels shows a 4:5 middle in the grid, so the
    /// cover keeps its title inside that.
    public var safeArea: NormalisedRect {
        switch self {
        case .cover: return NormalisedRect(x: 0.06, y: 0.15, width: 0.88, height: 0.7)
        default: return NormalisedRect(x: 0.05, y: 0.06, width: 0.9, height: 0.88)
        }
    }

    public var fileName: String { "thumbnail-\(rawValue).\(fileExtension)" }
}

/// Colours and font for the title, from DESIGN.md until the brand kit
/// supplies the builder's own.
public struct ThumbnailStyle: Codable, Hashable, Sendable {
    public var fontName: String
    public var textHex: String
    /// Shade behind the title, so it reads on any frame.
    public var shadeHex: String
    /// The builder's ring around the camera bubble. Identity, not state.
    public var ringHex: String

    public init(fontName: String = "Bricolage Grotesque", textHex: String = "#FFFFFF",
                shadeHex: String = "#121212", ringHex: String = "#E0A21B") {
        self.fontName = fontName
        self.textHex = textHex
        self.shadeHex = shadeHex
        self.ringHex = ringHex
    }

    public static let standard = ThumbnailStyle()

    /// 0xRRGGBB from "#RRGGBB", or nil.
    public static func rgb(_ hex: String) -> UInt32? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }
}

/// What the user set up for this take's thumbnail. Saved as
/// thumbnails/thumbnail.json so it opens the way they left it.
public struct ThumbnailDesign: Codable, Hashable, Sendable {
    public var version = 1
    /// The frame, in seconds of the take.
    public var time: Double
    public var title: String
    /// Top left of the title box, normalized over the image.
    public var titleX: Double
    public var titleY: Double
    /// Title box width as a share of the image width.
    public var titleWidth: Double
    /// Show the camera bubble (needs camera.mov).
    public var showFace: Bool
    /// Centre of the camera bubble, normalized, and its diameter as a
    /// share of the image's short edge.
    public var faceX: Double
    public var faceY: Double
    public var faceSize: Double
    public var sizes: [ThumbnailSize]
    public var style: ThumbnailStyle

    public init(time: Double, title: String, titleX: Double = 0.05, titleY: Double = 0.56,
                titleWidth: Double = 0.62, showFace: Bool = true,
                faceX: Double = 0.82, faceY: Double = 0.72, faceSize: Double = 0.48,
                sizes: [ThumbnailSize] = [.youtube], style: ThumbnailStyle = .standard) {
        self.time = time
        self.title = title
        self.titleX = titleX
        self.titleY = titleY
        self.titleWidth = titleWidth
        self.showFace = showFace
        self.faceX = faceX
        self.faceY = faceY
        self.faceSize = faceSize
        self.sizes = sizes
        self.style = style
    }

    /// Moves the title box, keeping it on the image.
    public mutating func moveTitle(x: Double, y: Double) {
        titleX = min(max(x, 0), 1 - min(titleWidth, 1))
        titleY = min(max(y, 0), 0.95)
    }

    public mutating func moveFace(x: Double, y: Double) {
        faceX = min(max(x, 0), 1)
        faceY = min(max(y, 0), 1)
    }

    public static func read(from url: URL) throws -> ThumbnailDesign {
        try JSONDecoder().decode(ThumbnailDesign.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Title text helpers. Fitting the type to pixels happens in the app
/// with Core Text; this decides the words.
public enum ThumbnailTitle {
    /// Big thumbnail titles work at three to six words.
    public static let maxWords = 6

    /// A title from the take: the best clip's title if there is one,
    /// otherwise the first sentence of the transcript.
    public static func suggested(transcript: Transcript?, clips: ClipList?, edits: EditList) -> String {
        if let best = clips?.visible.first {
            return shorten(best.title)
        }
        guard let transcript else { return "" }
        let finder = ClipFinder()
        let first = finder.sentences(transcript: transcript, edits: edits).first?.words ?? []
        return ClipFinder.title(for: first, maxWords: maxWords)
    }

    /// Cuts a title down to `maxWords`, without a trailing ellipsis.
    public static func shorten(_ title: String) -> String {
        var words = title.split(separator: " ").map(String.init)
        if words.count > maxWords { words = Array(words.prefix(maxWords)) }
        var text = words.joined(separator: " ")
        while let c = text.last, ".,;:!…".contains(c) { text.removeLast() }
        return text
    }

    /// Greedy line breaks at `maxCharacters` per line, never splitting a
    /// word. Used to balance lines before fitting the font size.
    public static func lines(_ title: String, maxCharacters: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in title.split(separator: " ") {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= maxCharacters {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
