import AVFoundation
import VisionOneKit

/// Lays a take's music and sound effects into a composition, for the
/// editor preview and for export alike, so both play the same mix. The
/// decisions (loops, the ducking curve, lanes) come from `SoundMixPlan`;
/// this only turns them into tracks and volume ramps.
enum SoundComposer {
    struct Added {
        var tracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        /// Something that couldn't be added, such as a moved music file.
        /// The rest still plays.
        var problem: String?
    }

    /// - Parameters:
    ///   - words: word spans in take seconds, for ducking.
    ///   - offset: seconds before the edited video starts in the
    ///     composition (a brand intro), so the sound lines up with it.
    static func add(_ plan: SoundPlan, timeline: ExportTimeline, words: [TimeSpan],
                    to composition: AVMutableComposition, offset: Double = 0) async -> Added {
        var added = Added()
        guard !plan.isEmpty, timeline.duration > 0 else { return added }

        // The music file's length decides how many loops are needed.
        var musicTrack: AVAssetTrack?
        var musicDuration: Double?
        if let bed = plan.music {
            do {
                let asset = AVURLAsset(url: try await SoundFiles.url(for: bed))
                musicTrack = try await asset.loadTracks(withMediaType: .audio).first
                musicDuration = try await asset.load(.duration).seconds
                if musicTrack == nil { added.problem = "\(bed.title) has no sound to play." }
            } catch {
                added.problem = "Couldn't play the music: \(error.localizedDescription)"
            }
        }

        let mix = SoundMixPlan(plan: plan, timeline: timeline, words: words,
                               musicDuration: musicTrack == nil ? nil : musicDuration)

        if let source = musicTrack, let envelope = mix.musicEnvelope, !mix.music.isEmpty,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            do {
                for piece in mix.music {
                    try track.insertTimeRange(CMTimeRange(start: time(piece.sourceStart), duration: time(piece.duration)),
                                              of: source, at: time(piece.outputStart + offset))
                }
                let parameters = AVMutableAudioMixInputParameters(track: track)
                if let first = envelope.points.first { parameters.setVolume(first.gain, at: .zero) }
                for (a, b) in zip(envelope.points, envelope.points.dropFirst()) where b.time > a.time {
                    parameters.setVolumeRamp(fromStartVolume: a.gain, toEndVolume: b.gain,
                                             timeRange: CMTimeRange(start: time(a.time + offset), end: time(b.time + offset)))
                }
                added.tracks.append(track)
                added.parameters.append(parameters)
            } catch {
                composition.removeTrack(track)
                added.problem = "Couldn't place the music: \(error.localizedDescription)"
            }
        }

        guard mix.laneCount > 0 else { return added }
        var sources: [String: AVAssetTrack] = [:]
        var lanes: [(AVMutableCompositionTrack, AVMutableAudioMixInputParameters)] = []
        for _ in 0..<mix.laneCount {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { break }
            lanes.append((track, AVMutableAudioMixInputParameters(track: track)))
        }
        for effect in mix.effects where effect.lane < lanes.count {
            do {
                if sources[effect.soundID] == nil {
                    let asset = AVURLAsset(url: try await SoundFiles.url(forLibrarySound: effect.soundID))
                    sources[effect.soundID] = try await asset.loadTracks(withMediaType: .audio).first
                }
                guard let source = sources[effect.soundID] else { continue }
                let (track, parameters) = lanes[effect.lane]
                let start = time(effect.outputStart + offset)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: time(effect.duration)), of: source, at: start)
                parameters.setVolume(effect.gain, at: start)
            } catch {
                added.problem = "Couldn't add a sound effect: \(error.localizedDescription)"
            }
        }
        for (track, parameters) in lanes {
            added.tracks.append(track)
            added.parameters.append(parameters)
        }
        return added
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}
