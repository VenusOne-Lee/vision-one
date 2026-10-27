import Foundation

/// Everything the preview and export need to lay sound under the edit,
/// worked out in output seconds: where each copy of the music goes, the
/// music's volume curve, and each accepted effect with its lane. The app
/// turns this into AVFoundation tracks and changes nothing else.
public struct SoundMixPlan: Equatable, Sendable {
    /// One copy of the music file placed on the edited video. Looping
    /// music is several pieces end to end.
    public struct MusicPiece: Equatable, Sendable {
        public let outputStart: Double
        /// Where in the music file this piece starts.
        public let sourceStart: Double
        public let duration: Double
    }

    public struct Effect: Equatable, Sendable {
        public let id: UUID
        public let soundID: String
        public let outputStart: Double
        public let duration: Double
        public let gain: Float
        /// Effects that overlap go on different tracks.
        public let lane: Int
    }

    public let music: [MusicPiece]
    public let musicEnvelope: MusicEnvelope?
    public let effects: [Effect]
    public let laneCount: Int

    /// - Parameters:
    ///   - timeline: the kept parts of the take, as preview or export plays them.
    ///   - words: word spans in take seconds, for ducking.
    ///   - musicDuration: length of the music file, or nil when it couldn't be read.
    ///   - effectDuration: length of an effect's sound; defaults to the library's.
    public init(plan: SoundPlan, timeline: ExportTimeline, words: [TimeSpan], musicDuration: Double?,
                settings: DuckingSettings = DuckingSettings(),
                effectDuration: (String) -> Double? = { SoundLibrary.sound(id: $0)?.duration }) {
        let duration = timeline.duration
        let speech = Speech.outputRegions(words: words, timeline: timeline, bridge: settings.bridge)

        var pieces: [MusicPiece] = []
        var envelope: MusicEnvelope?
        if let bed = plan.music, let length = musicDuration, length > 0.05, duration > 0 {
            var cursor = 0.0
            repeat {
                let piece = min(length, duration - cursor)
                pieces.append(MusicPiece(outputStart: cursor, sourceStart: 0, duration: piece))
                cursor += piece
            } while bed.loops && duration - cursor > 0.01
            envelope = MusicEnvelope(duration: min(duration, cursor), bed: bed, speech: speech, settings: settings)
        }
        music = pieces
        musicEnvelope = envelope

        // Accepted effects whose moment survived the cuts, in time order.
        let placed: [(PlacedEffect, Double, Double)] = plan.effects
            .filter { $0.state == .accepted }
            .compactMap { effect in
                guard let start = timeline.outputTime(forSource: effect.at),
                      let length = effectDuration(effect.soundID) else { return nil }
                let clipped = min(length, duration - start)
                guard clipped > 0.01 else { return nil }
                return (effect, start, clipped)
            }
            .sorted { $0.1 < $1.1 }

        var laneEnds: [Double] = []
        var effects: [Effect] = []
        for (effect, start, length) in placed {
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 <= start + 1e-6 }) {
                lane = free
                laneEnds[free] = start + length
            } else {
                lane = laneEnds.count
                laneEnds.append(start + length)
            }
            let onSpeech = Speech.overlaps(TimeSpan(start: start, end: start + length), speech)
            let db = effect.levelDB - (onSpeech ? settings.effectDuckDB : 0)
            effects.append(Effect(id: effect.id, soundID: effect.soundID, outputStart: start,
                                  duration: length, gain: MusicEnvelope.gain(db: db), lane: lane))
        }
        self.effects = effects
        laneCount = laneEnds.count
    }

    public var isEmpty: Bool { music.isEmpty && effects.isEmpty }
}
