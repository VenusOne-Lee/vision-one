import AVFoundation
import VisionOneKit

/// Puts the kept voice tools into an export: the cleaned voice in place
/// of the mic track, and each kept word fix on its own track with the
/// original word muted under it. Nothing kept means nothing changes.
enum VoiceComposer {
    /// The audio sources to cut from: the mic swapped for the cleaned
    /// voice when that's kept. The cleaned file is on the take's clock.
    static func sources(_ sources: [(track: AVAssetTrack, range: CMTimeRange)],
                        take: Take) async -> [(track: AVAssetTrack, range: CMTimeRange)] {
        let edits = VoiceEdits.load(from: take.voiceURL)
        guard let clean = edits.cleanVoice, clean.kept else { return sources }
        let asset = AVURLAsset(url: take.folder.appendingPathComponent(clean.file))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange),
              let index = await MicTrack.micIndex(of: sources.map(\.track), take: take) else { return sources }
        var swapped = sources
        swapped[index] = (track, range)
        return swapped
    }

    struct Added {
        var tracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        /// Output spans (composition seconds) to silence on the mic track.
        var mutes: [TimeSpan] = []
    }

    /// Adds kept word fixes to the composition. `offset` is the brand
    /// intro's length, as for music.
    static func addFixes(for take: Take, timeline: ExportTimeline, to composition: AVMutableComposition,
                         offset: Double) async -> Added {
        var added = Added()
        let placements = VoiceEdits.load(from: take.voiceURL).placements(on: timeline)
        guard !placements.isEmpty,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return added
        }
        for placement in placements {
            let asset = AVURLAsset(url: take.folder.appendingPathComponent(placement.fix.file))
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange) else { continue }
            let at = CMTime(seconds: placement.at + offset, preferredTimescale: 600)
            if (try? track.insertTimeRange(range, of: source, at: at)) != nil {
                added.mutes.append(TimeSpan(start: placement.mute.start + offset, end: placement.mute.end + offset))
            }
        }
        added.tracks.append(track)
        added.parameters.append(AVMutableAudioMixInputParameters(track: track))
        return added
    }

    /// Silences the mic under each fixed word, with 10 ms edges so it doesn't click.
    static func mute(_ spans: [TimeSpan], on parameters: AVMutableAudioMixInputParameters) {
        let edge = CMTime(seconds: 0.01, preferredTimescale: 600)
        for span in spans {
            let start = CMTime(seconds: span.start, preferredTimescale: 600)
            let end = CMTime(seconds: span.end, preferredTimescale: 600)
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: start - edge, duration: edge))
            parameters.setVolume(0, at: start)
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: end, duration: edge))
        }
    }
}
