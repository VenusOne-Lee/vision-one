import Foundation

/// Makes Vision One's own sounds from recipes: filtered noise for
/// whooshes, decaying sines for pops and dings, chords for music beds.
/// The output is the same on every Mac, so a render can be cached and
/// tests can check it. Mono, -1...1, at `sampleRate`.
public enum SoundSynth {
    public static let sampleRate = 48_000.0

    /// Renders a library sound, or nil for an id the library doesn't have.
    public static func render(_ id: String) -> [Float]? {
        let samples: [Float]
        switch id {
        case "whoosh": samples = whoosh()
        case "pop": samples = pop()
        case "click": samples = click()
        case "ding": samples = ding()
        case "rise": samples = rise()
        case "thud": samples = thud()
        case "still-water": samples = music(.stillWater)
        case "workbench": samples = music(.workbench)
        case "launch-day": samples = music(.launchDay)
        default: return nil
        }
        return normalized(samples, peak: 0.89) // -1 dBFS
    }

    // MARK: Effects

    static func whoosh(duration: Double = 0.7) -> [Float] {
        var noise = Noise(seed: 0x5EED_0001)
        var filter = Biquad()
        return generate(duration) { t in
            // Sweep up to the peak, then fall away.
            let peak = 0.35
            let frequency = t < peak
                ? 300 * pow(3500.0 / 300, t / peak)
                : 3500 * pow(600.0 / 3500, (t - peak) / (duration - peak))
            filter.setBandPass(frequency: frequency, q: 1.4)
            let envelope = t < 0.3 ? pow(t / 0.3, 2) : exp(-(t - 0.3) / 0.12)
            return Float(envelope) * filter.process(noise.next())
        }
    }

    static func pop(duration: Double = 0.15) -> [Float] {
        var phase = 0.0
        return generate(duration) { t in
            let frequency = 620 * pow(140.0 / 620, min(1, t / 0.09))
            phase += 2 * .pi * frequency / sampleRate
            return Float(sin(phase) * exp(-t / 0.03))
        }
    }

    static func click(duration: Double = 0.05) -> [Float] {
        var noise = Noise(seed: 0x5EED_0003)
        var last: Float = 0
        return generate(duration) { t in
            let n = noise.next()
            defer { last = n }
            let bright = n - last // a first difference keeps only the top end
            return Float(exp(-t / 0.004)) * (0.6 * bright + 0.4 * Float(sin(2 * .pi * 2000 * t)))
        }
    }

    static func ding(duration: Double = 1.2) -> [Float] {
        generate(duration) { t in
            let attack = min(1, t / 0.003)
            let body = sin(2 * .pi * 1318.5 * t) + 0.35 * sin(2 * .pi * 2637 * t) + 0.1 * sin(2 * .pi * 3955.5 * t)
            return Float(attack * exp(-t / 0.35) * body)
        }
    }

    static func rise(duration: Double = 1.4) -> [Float] {
        var noise = Noise(seed: 0x5EED_0005)
        var filter = Biquad()
        var phase = 0.0
        return generate(duration) { t in
            let progress = t / duration
            filter.setBandPass(frequency: 400 * pow(5000.0 / 400, progress), q: 1.2)
            phase += 2 * .pi * (220 * pow(4, progress)) / sampleRate
            let envelope = pow(progress, 2) * min(1, (duration - t) / 0.05)
            return Float(envelope) * (0.7 * filter.process(noise.next()) + 0.3 * Float(sin(phase)))
        }
    }

    static func thud(duration: Double = 0.5) -> [Float] {
        var noise = Noise(seed: 0x5EED_0006)
        var filter = Biquad()
        filter.setLowPass(frequency: 300, q: 0.7)
        var phase = 0.0
        return generate(duration) { t in
            phase += 2 * .pi * (90 * pow(0.5, min(1, t / 0.2))) / sampleRate
            let body = sin(phase) * exp(-t / 0.12)
            let hit = Double(filter.process(noise.next())) * exp(-t / 0.02)
            return Float(body + 0.5 * hit)
        }
    }

    // MARK: Music

    /// A chord loop, with optional arpeggio and drums. Every chord lasts
    /// two bars; the tail of the last chord wraps round into the first,
    /// so the loop has no seam.
    public struct MusicRecipe: Sendable {
        /// MIDI note numbers of each chord.
        public let chords: [[Int]]
        public let bpm: Double
        public let padLevel: Double
        public let arpeggio: Bool
        public let drums: Bool

        public var beat: Double { 60 / bpm }
        public var chordDuration: Double { beat * 8 }
        public var loopDuration: Double { chordDuration * Double(chords.count) }

        public static let stillWater = MusicRecipe(
            chords: [[48, 55, 64, 71], [45, 52, 60, 67], [41, 48, 57, 64], [43, 50, 59, 64]], // Cmaj7 Am7 Fmaj7 G6
            bpm: 60, padLevel: 1, arpeggio: false, drums: false)
        public static let workbench = MusicRecipe(
            chords: [[50, 57, 65, 69], [46, 53, 62, 65], [43, 50, 58, 65], [45, 52, 61, 64]], // Dm Bb Gm7 A
            bpm: 90, padLevel: 0.6, arpeggio: true, drums: false)
        public static let launchDay = MusicRecipe(
            chords: [[48, 55, 64, 67], [43, 50, 59, 62], [45, 52, 60, 64], [41, 48, 57, 60]], // C G Am F
            bpm: 112, padLevel: 0.5, arpeggio: true, drums: true)
    }

    static func music(_ recipe: MusicRecipe) -> [Float] {
        let length = Int((recipe.loopDuration * sampleRate).rounded())
        var out = [Double](repeating: 0, count: length)

        func add(at start: Double, duration: Double, _ voice: (Double) -> Double) {
            let first = Int((start * sampleRate).rounded())
            let count = Int((duration * sampleRate).rounded())
            for n in 0..<count {
                out[(first + n) % length] += voice(Double(n) / sampleRate)
            }
        }

        let attack = 0.6, tail = 1.2
        for (i, chord) in recipe.chords.enumerated() {
            let start = Double(i) * recipe.chordDuration
            let hold = recipe.chordDuration
            // Pad: three slightly detuned sines per note, slow in and out.
            for note in chord {
                let f = frequency(note)
                add(at: start, duration: hold + tail) { t in
                    let envelope = min(1, t / attack) * (t > hold ? max(0, 1 - (t - hold) / tail) : 1)
                    let tone = sin(2 * .pi * f * t) + sin(2 * .pi * f * 1.002 * t) + sin(2 * .pi * f * 0.998 * t)
                        + 0.25 * sin(2 * .pi * f * 2 * t)
                    return recipe.padLevel * 0.08 * envelope * tone
                }
            }
            if recipe.arpeggio {
                // Eighth notes walking up the chord an octave higher.
                for step in 0..<16 {
                    let note = chord[step % chord.count] + 12
                    let f = frequency(note)
                    add(at: start + Double(step) * recipe.beat / 2, duration: 0.9) { t in
                        0.12 * exp(-t / 0.22) * (sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * f * 2 * t))
                    }
                }
            }
            if recipe.drums {
                var noise = Noise(seed: UInt64(0xD0_0000 + i))
                for beatIndex in 0..<8 {
                    let beatStart = start + Double(beatIndex) * recipe.beat
                    // Kick on every beat, bass on one and three of each bar.
                    add(at: beatStart, duration: 0.3) { t in
                        let f = 45 + 65 * exp(-t / 0.03)
                        return 0.35 * exp(-t / 0.12) * sin(2 * .pi * f * t)
                    }
                    if beatIndex % 2 == 0 {
                        let f = frequency(chord[0] - 12)
                        add(at: beatStart, duration: recipe.beat * 2) { t in
                            0.18 * exp(-t / 0.5) * sin(2 * .pi * f * t)
                        }
                    }
                    var last: Float = 0
                    add(at: beatStart + recipe.beat / 2, duration: 0.06) { t in
                        let n = noise.next()
                        defer { last = n }
                        return 0.12 * exp(-t / 0.015) * Double(n - last)
                    }
                }
            }
        }
        return out.map { Float($0) }
    }

    static func frequency(_ midi: Int) -> Double {
        440 * pow(2, Double(midi - 69) / 12)
    }

    // MARK: Helpers

    static func generate(_ duration: Double, _ sample: (Double) -> Float) -> [Float] {
        let count = Int((duration * sampleRate).rounded())
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            out[n] = sample(Double(n) / sampleRate)
        }
        return out
    }

    static func normalized(_ samples: [Float], peak: Float) -> [Float] {
        let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard loudest > 0 else { return samples }
        let gain = peak / loudest
        return samples.map { $0 * gain }
    }

    /// White noise from a fixed seed, so every render is the same.
    struct Noise {
        var state: UInt64

        init(seed: UInt64) { state = seed == 0 ? 1 : seed }

        mutating func next() -> Float {
            // xorshift64*
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = state &* 2_685_821_657_736_338_717
            return Float(Double(value >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    /// A two-pole filter (RBJ cookbook) whose frequency can move every sample.
    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func setBandPass(frequency: Double, q: Double) {
            let w = 2 * .pi * min(frequency, SoundSynth.sampleRate * 0.45) / SoundSynth.sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b1 = 0
            b2 = -alpha / a0
            a1 = -2 * cos(w) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func setLowPass(frequency: Double, q: Double) {
            let w = 2 * .pi * min(frequency, SoundSynth.sampleRate * 0.45) / SoundSynth.sampleRate
            let alpha = sin(w) / (2 * q)
            let a0 = 1 + alpha
            b0 = (1 - cos(w)) / 2 / a0
            b1 = (1 - cos(w)) / a0
            b2 = b0
            a1 = -2 * cos(w) / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Float) -> Float {
            let input = Double(x)
            let y = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = input
            y2 = y1; y1 = y
            return Float(y)
        }
    }
}

/// 16-bit PCM WAV, the simplest file AVFoundation reads everywhere.
public enum WAVFile {
    /// Encodes mono samples, copied to every channel.
    public static func data(samples: [Float], sampleRate: Int, channels: Int = 2) -> Data {
        let channels = max(1, channels)
        let bytesPerFrame = 2 * channels
        let dataSize = samples.count * bytesPerFrame
        var data = Data(capacity: 44 + dataSize)

        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * bytesPerFrame))
        append16(UInt16(bytesPerFrame))
        append16(16)
        append("data")
        append32(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count * channels)
        for (i, sample) in samples.enumerated() {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            for c in 0..<channels { pcm[i * channels + c] = value.littleEndian }
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
