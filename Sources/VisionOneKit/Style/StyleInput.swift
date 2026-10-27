import Foundation

/// A colour, 0...1 per channel.
public struct StyleRGB: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    /// "#1F3FBF".
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Relative luminance, 0 black to 1 white.
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public var saturation: Double {
        let hi = max(r, g, b), lo = min(r, g, b)
        return hi == 0 ? 0 : (hi - lo) / hi
    }

    func distance(to other: StyleRGB) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// Words Vision read on screen, with where they sit.
public struct StyleTextBox: Codable, Equatable, Sendable {
    public var rect: NormalisedRect
    public var text: String

    public init(rect: NormalisedRect, text: String) {
        self.rect = rect
        self.text = text
    }
}

/// What the sampler measured on one frame. Frames themselves are never
/// kept: only these numbers.
public struct StyleFrame: Sendable {
    public var time: Double
    /// A colour histogram summing to 1 (see `StyleMeasure.frame`), for
    /// finding cuts.
    public var signature: [Double]
    /// Average colours of a grid of cells, for the palette.
    public var colours: [StyleRGB]
    /// Face boxes, or nil when Vision didn't look at this frame (it reads
    /// one frame in four).
    public var faces: [NormalisedRect]?
    /// On-screen words, or nil when Vision didn't look at this frame.
    public var text: [StyleTextBox]?

    public init(time: Double, signature: [Double], colours: [StyleRGB] = [],
                faces: [NormalisedRect]? = nil, text: [StyleTextBox]? = nil) {
        self.time = time
        self.signature = signature
        self.colours = colours
        self.faces = faces
        self.text = text
    }

    var wasRead: Bool { faces != nil || text != nil }
}

/// A stretch of sound, as macOS SoundAnalysis labelled it.
public struct StyleSoundWindow: Sendable {
    public var start: Double
    public var duration: Double
    /// 0...1 confidence that someone is talking.
    public var speech: Double
    /// 0...1 confidence that music is playing.
    public var music: Double
    /// Loudness in dBFS (0 is full scale, -60 is near silence).
    public var loudness: Double

    public init(start: Double, duration: Double, speech: Double, music: Double, loudness: Double) {
        self.start = start
        self.duration = duration
        self.speech = speech
        self.music = music
        self.loudness = loudness
    }

    var end: Double { start + duration }
    var hasSpeech: Bool { speech >= 0.5 }
    var hasMusic: Bool { music >= 0.5 }
}

/// Everything the scanner looks at, from a file or a playing window.
public struct StyleInput: Sendable {
    /// Seconds of video that were read (a long video is read up to
    /// `StyleMeasure.maxSeconds`).
    public var duration: Double
    /// Display size, after rotation.
    public var width: Double
    public var height: Double
    public var frames: [StyleFrame]
    public var sound: [StyleSoundWindow]
    /// Loudness envelope (linear RMS, 0...1) at `envelopeRate` a second,
    /// for finding the beat.
    public var envelope: [Double]
    public var envelopeRate: Double

    public init(duration: Double, width: Double, height: Double, frames: [StyleFrame],
                sound: [StyleSoundWindow] = [], envelope: [Double] = [], envelopeRate: Double = 20) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frames = frames.sorted { $0.time < $1.time }
        self.sound = sound.sorted { $0.start < $1.start }
        self.envelope = envelope
        self.envelopeRate = envelopeRate
    }
}

/// How the sampler reads a video, kept here so the app and tests agree.
public enum StyleMeasure {
    /// Frames a second for cuts and colour.
    public static let framesPerSecond: Double = 4
    /// Vision (faces, words) looks at one frame in this many: once a second.
    public static let visionEvery = 4
    /// Longer videos are read up to here; style shows in the first minutes.
    public static let maxSeconds: Double = 180
    /// Frames are shrunk to this width before measuring.
    public static let sampleWidth = 160
    /// Colour cells across and down for the palette.
    public static let grid = 4
    /// Envelope rate for the beat finder.
    public static let envelopeRate: Double = 20

    /// When to grab frames.
    public static func sampleTimes(duration: Double) -> [Double] {
        let end = min(max(duration, 0), maxSeconds)
        let step = 1 / framesPerSecond
        var times: [Double] = []
        var t = step / 2
        while t < end {
            times.append(t)
            t += step
        }
        return times
    }

    /// Whether Vision should read the frame at this index.
    public static func readsVision(at index: Int) -> Bool { index % visionEvery == 0 }

    /// Signature and colours from an RGBA (or BGRA when `bgra`) buffer.
    /// The signature is a 4×4×4 RGB histogram for each quarter of the
    /// frame, so two shots with the same colours in different places still
    /// tell apart. It sums to 1.
    public static func frame(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                             bgra: Bool = false) -> (signature: [Double], colours: [StyleRGB]) {
        guard width > 0, height > 0, pixels.count >= bytesPerRow * height else { return ([], []) }
        var hist = [Double](repeating: 0, count: 4 * 64)
        let cells = grid * grid
        var sums = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: cells)
        let ri = bgra ? 2 : 0, bi = bgra ? 0 : 2
        for y in 0..<height {
            let row = y * bytesPerRow
            let qy = y * 2 / height
            let cy = y * grid / height
            for x in 0..<width {
                let p = row + x * 4
                let r = Int(pixels[p + ri]), g = Int(pixels[p + 1]), b = Int(pixels[p + bi])
                let quarter = qy * 2 + x * 2 / width
                hist[quarter * 64 + (r >> 6) * 16 + (g >> 6) * 4 + (b >> 6)] += 1
                let c = cy * grid + x * grid / width
                sums[c].0 += Double(r)
                sums[c].1 += Double(g)
                sums[c].2 += Double(b)
                sums[c].3 += 1
            }
        }
        let total = hist.reduce(0, +)
        let signature = total > 0 ? hist.map { $0 / total } : hist
        let colours = sums.compactMap { s -> StyleRGB? in
            guard s.3 > 0 else { return nil }
            return StyleRGB(r: s.0 / s.3 / 255, g: s.1 / s.3 / 255, b: s.2 / s.3 / 255)
        }
        return (signature, colours)
    }
}
