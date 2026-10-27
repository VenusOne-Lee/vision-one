import Foundation

/// The places a video can be exported for. Every preset writes an H.264
/// MP4 with AAC sound, because that plays everywhere: WhatsApp, browsers,
/// phones, Slack, GitHub. Vertical and square formats come with reframing
/// in v0.2.
public enum ExportPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Full recorded size, up to 4K (H.264's practical limit).
    case original
    case hd1080
    case hd720
    /// Under 16 MB so it sends in a WhatsApp chat on mobile data.
    case whatsapp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        case .whatsapp: return "WhatsApp"
        }
    }

    public var detail: String {
        switch self {
        case .original: return "Full size, best quality"
        case .hd1080: return "YouTube, LinkedIn, X"
        case .hd720: return "Smaller file, still sharp"
        case .whatsapp: return "Under 16 MB"
        }
    }

    /// Appended to the take's name for the exported file.
    public var fileSuffix: String {
        switch self {
        case .original: return ""
        case .hd1080: return " (1080p)"
        case .hd720: return " (720p)"
        case .whatsapp: return " (WhatsApp)"
        }
    }

    /// Hard ceiling on the file, or nil for no limit.
    public var sizeLimitBytes: Int64? {
        switch self {
        case .whatsapp: return 16_000_000
        default: return nil
        }
    }
}

/// What the recording looks like before export.
public struct ExportSource: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Double

    public init(width: Int, height: Int, frameRate: Double) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

/// Exactly what the encoder is asked for.
public struct ExportSettings: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var videoBitRate: Int
    public var audioBitRate: Int
    public var audioChannels: Int

    /// Rough size in bytes for a video of this length, including about
    /// 2% for the MP4 container.
    public func estimatedBytes(duration: Double) -> Int64 {
        let bits = Double(videoBitRate + audioBitRate) * max(0, duration)
        return Int64(bits / 8 * 1.02)
    }
}

public enum ExportPlanError: Error, Equatable, Sendable {
    /// Too long to look watchable under the preset's size limit. `parts`
    /// is how many pieces it would have to be split into.
    case tooLongForSizeLimit(maxDuration: Double, parts: Int)
    case emptyVideo
}

/// Turns a preset, the source and the edited length into encoder
/// settings. Plain arithmetic, so it's tested without AVFoundation.
public enum ExportPlanner {
    /// Bits per pixel per frame for screen recordings in H.264. Text and
    /// UI need more than camera video; above 30 fps each frame changes
    /// less, so it needs fewer bits.
    static let bitsPerPixel = 0.1
    static let bitsPerPixelHighFrameRate = 0.07
    static let maxVideoBitRate = 40_000_000
    /// H.264 encoders on the Mac top out around 4096 wide; 3840 keeps
    /// every player happy.
    static let maxLongEdge = 3840

    /// Size-limited exports aim below the limit, because a single-pass
    /// encoder only hits its average bitrate approximately.
    static let sizeLimitHeadroom = 0.9

    /// Steps the WhatsApp preset walks down until the bitrate fits. The
    /// first one with at least `minBitsPerPixel` wins.
    struct Rung: Equatable {
        let shortEdge: Int
        let frameRate: Int
        let minBitsPerPixel: Double
        let audioBitRate: Int
        let audioChannels: Int
    }

    static let sizeLimitedLadder: [Rung] = [
        Rung(shortEdge: 720, frameRate: 30, minBitsPerPixel: 0.05, audioBitRate: 96_000, audioChannels: 2),
        Rung(shortEdge: 540, frameRate: 30, minBitsPerPixel: 0.05, audioBitRate: 96_000, audioChannels: 2),
        Rung(shortEdge: 480, frameRate: 24, minBitsPerPixel: 0.05, audioBitRate: 64_000, audioChannels: 1),
        Rung(shortEdge: 360, frameRate: 24, minBitsPerPixel: 0.04, audioBitRate: 48_000, audioChannels: 1),
    ]

    public static func settings(for preset: ExportPreset, source: ExportSource, duration: Double) throws -> ExportSettings {
        guard duration > 0, source.width > 0, source.height > 0 else { throw ExportPlanError.emptyVideo }

        let sourceRate = source.frameRate > 0 ? source.frameRate : 30
        switch preset {
        case .original:
            return plain(source: source, shortEdge: nil, frameRate: min(60, Int(sourceRate.rounded())))
        case .hd1080:
            return plain(source: source, shortEdge: 1080, frameRate: min(60, Int(sourceRate.rounded())))
        case .hd720:
            return plain(source: source, shortEdge: 720, frameRate: min(30, Int(sourceRate.rounded())))
        case .whatsapp:
            return try sizeLimited(source: source, duration: duration,
                                   limit: preset.sizeLimitBytes ?? 16_000_000)
        }
    }

    /// The longest edited video the preset can take before it has to be
    /// split, or nil when the preset has no size limit.
    public static func maxDuration(for preset: ExportPreset,
                                   source: ExportSource = ExportSource(width: 1920, height: 1080, frameRate: 30)) -> Double? {
        guard let limit = preset.sizeLimitBytes, let last = sizeLimitedLadder.last else { return nil }
        let size = fit(width: source.width, height: source.height, shortEdge: last.shortEdge)
        let minVideo = Double(size.width * size.height * last.frameRate) * last.minBitsPerPixel
        return budgetBits(limit) / (minVideo + Double(last.audioBitRate))
    }

    private static func plain(source: ExportSource, shortEdge: Int?, frameRate: Int) -> ExportSettings {
        let size = fit(width: source.width, height: source.height, shortEdge: shortEdge)
        let rate = max(1, frameRate)
        let bpp = rate > 30 ? bitsPerPixelHighFrameRate : bitsPerPixel
        let bitRate = min(maxVideoBitRate, Int(Double(size.width * size.height * rate) * bpp))
        return ExportSettings(width: size.width, height: size.height, frameRate: rate,
                              videoBitRate: bitRate, audioBitRate: 160_000, audioChannels: 2)
    }

    private static func sizeLimited(source: ExportSource, duration: Double, limit: Int64) throws -> ExportSettings {
        let totalBitRate = budgetBits(limit) / duration
        let sourceRate = Int((source.frameRate > 0 ? source.frameRate : 30).rounded())

        for rung in sizeLimitedLadder {
            let size = fit(width: source.width, height: source.height, shortEdge: rung.shortEdge)
            let rate = min(rung.frameRate, max(1, sourceRate))
            let pixelsPerSecond = Double(size.width * size.height * rate)
            let videoBitRate = totalBitRate - Double(rung.audioBitRate)
            guard videoBitRate / pixelsPerSecond >= rung.minBitsPerPixel else { continue }
            // Short videos don't need the whole budget.
            let capped = min(videoBitRate, pixelsPerSecond * bitsPerPixel)
            return ExportSettings(width: size.width, height: size.height, frameRate: rate,
                                  videoBitRate: Int(capped), audioBitRate: rung.audioBitRate,
                                  audioChannels: rung.audioChannels)
        }

        let preset = ExportPreset.allCases.first { $0.sizeLimitBytes == limit } ?? .whatsapp
        let longest = maxDuration(for: preset, source: source) ?? duration
        throw ExportPlanError.tooLongForSizeLimit(maxDuration: longest,
                                                  parts: Int((duration / longest).rounded(.up)))
    }

    /// Usable bits under a limit, after headroom and the container.
    private static func budgetBits(_ limit: Int64) -> Double {
        Double(limit) * 8 * sizeLimitHeadroom / 1.02
    }

    /// Scales so the short edge is at most `shortEdge` and the long edge at
    /// most `maxLongEdge`, keeping the shape. Never scales up. Both sides
    /// come out even, which H.264 needs.
    static func fit(width: Int, height: Int, shortEdge: Int?) -> (width: Int, height: Int) {
        let short = Double(min(width, height))
        let long = Double(max(width, height))
        var scale = 1.0
        if let shortEdge, short > Double(shortEdge) { scale = Double(shortEdge) / short }
        if long * scale > Double(maxLongEdge) { scale = Double(maxLongEdge) / long }
        func even(_ value: Double) -> Int { max(2, Int((value * scale / 2).rounded()) * 2) }
        return (even(Double(width)), even(Double(height)))
    }
}
