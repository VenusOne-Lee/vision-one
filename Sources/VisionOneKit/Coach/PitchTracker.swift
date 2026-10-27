import Foundation

/// Finds the pitch of a short frame of voice (about 40 ms), on the Mac,
/// with the YIN method (de Cheveigné and Kawahara, 2002): the lag where
/// the frame best matches a shifted copy of itself is one period. Used by
/// Rehearse's energy meter, where pitch that moves reads as lively and
/// pitch that stays flat reads as monotone.
public struct PitchTracker: Sendable {
    public var sampleRate: Double
    /// Speaking voices sit between about 70 Hz and 400 Hz.
    public var minHz: Double = 70
    public var maxHz: Double = 400
    /// Lower is stricter. 0.15 is the paper's usual value.
    public var threshold: Float = 0.15
    /// Frames quieter than this (dB RMS) are treated as silence.
    public var silenceDB: Float = -50

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Samples needed for one estimate: two of the longest periods.
    public var frameLength: Int { Int(sampleRate / minHz) * 2 }

    /// Pitch in hertz, or nil for silence and unvoiced sounds (s, f, breath).
    public func pitch(of frame: [Float]) -> Double? {
        let maxLag = Int(sampleRate / minHz)
        let minLag = max(2, Int(sampleRate / maxHz))
        guard frame.count >= maxLag * 2 else { return nil }
        var energy: Float = 0
        for s in frame { energy += s * s }
        let rms = (energy / Float(frame.count)).squareRoot()
        guard rms > 0, 20 * log10(rms) > silenceDB else { return nil }

        let window = frame.count - maxLag
        // Difference function, then its cumulative mean normalised form.
        var d = [Float](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var sum: Float = 0
            for i in 0..<window {
                let delta = frame[i] - frame[i + lag]
                sum += delta * delta
            }
            d[lag] = sum
        }
        var cmnd = [Float](repeating: 1, count: maxLag + 1)
        var running: Float = 0
        for lag in 1...maxLag {
            running += d[lag]
            cmnd[lag] = running > 0 ? d[lag] * Float(lag) / running : 1
        }
        var lag = minLag
        var found: Int?
        while lag <= maxLag {
            if cmnd[lag] < threshold {
                // Walk down to the bottom of this dip.
                while lag + 1 <= maxLag, cmnd[lag + 1] < cmnd[lag] { lag += 1 }
                found = lag
                break
            }
            lag += 1
        }
        guard let tau = found else { return nil }
        // Parabolic interpolation for a lag between samples.
        var refined = Double(tau)
        if tau > 1, tau < maxLag {
            let a = cmnd[tau - 1], b = cmnd[tau], c = cmnd[tau + 1]
            let denominator = a + c - 2 * b
            if denominator != 0 { refined += Double((a - c) / (2 * denominator)) }
        }
        return sampleRate / refined
    }

    /// Semitones between two pitches, for spread that doesn't depend on
    /// how high a voice is.
    public static func semitones(_ hz: Double, from reference: Double) -> Double {
        12 * log2(hz / reference)
    }
}
