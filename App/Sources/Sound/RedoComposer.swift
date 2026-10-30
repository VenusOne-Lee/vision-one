import AVFoundation
import VisionOneKit

/// Lays redone sentences into a composition, for the editor preview and
/// for export alike: each new line on its own track, fitted to the
/// original sentence's slot, and the original voice muted under it.
/// Fitting changes the speed a little (0.8× to 1.25×); play it back
/// with a pitch-keeping algorithm (`.spectral`) so the voice stays true.
enum RedoComposer {
    struct Added {
        var tracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        /// Output seconds (offset included) where the original voice is
        /// replaced and should be silent.
        var mutes: [Range<Double>] = []
    }

    /// Fade at each end of a redone line, so the joins don't click.
    static let fade = 0.03

    static func add(_ redos: [LineRedo], take: Take, timeline: ExportTimeline,
                    to composition: AVMutableComposition, offset: Double = 0) async -> Added {
        var added = Added()
        for redo in redos {
            guard let output = timeline.outputRange(forSource: redo.slot),
                  let source = try? await AVURLAsset(url: take.folder.appendingPathComponent(redo.file))
                    .loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let at = time(output.lowerBound + offset)
            let clip = CMTimeRange(start: time(redo.clipStart), end: time(redo.clipEnd))
            do {
                try track.insertTimeRange(clip, of: source, at: at)
                track.scaleTimeRange(CMTimeRange(start: at, duration: clip.duration),
                                     toDuration: time(redo.slot.duration))
            } catch {
                composition.removeTrack(track)
                continue
            }
            let end = at + time(redo.slot.duration)
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                     timeRange: CMTimeRange(start: at, duration: time(fade)))
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: end - time(fade), duration: time(fade)))
            added.tracks.append(track)
            added.parameters.append(parameters)
            added.mutes.append((output.lowerBound + offset)..<(output.upperBound + offset))
        }
        return added
    }

    /// Silences the original voice under each redone line, with short
    /// fades either side.
    static func mute(_ parameters: AVMutableAudioMixInputParameters, during mutes: [Range<Double>], gain: Float = 1) {
        for range in mutes {
            let start = time(max(0, range.lowerBound - fade))
            parameters.setVolumeRamp(fromStartVolume: gain, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: start, duration: time(fade)))
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: time(range.lowerBound), end: time(range.upperBound)))
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: gain,
                                     timeRange: CMTimeRange(start: time(range.upperBound), duration: time(fade)))
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}
