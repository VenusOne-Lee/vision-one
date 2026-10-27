import AVFoundation
import ScreenCaptureKit
import VisionOneKit

/// Writes ScreenCaptureKit's sample buffers to screen.mov with one video
/// track and separate system sound and mic tracks, each left out when
/// switched off. The file is written in fragments every 2 seconds, so a
/// crash loses seconds, not the take. Next to it, audio-tracks.json
/// lists which source each audio track holds, so the transcriber picks
/// the mic without guessing.
///
/// Used only from the capture queue, so it needs no locking.
final class TakeWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    /// Nil when System sound is switched off.
    private let systemAudio: AVAssetWriterInput?
    /// Nil when Microphone access is off; the take then has no mic track.
    private let mic: AVAssetWriterInput?

    /// Host time of the first frame. Every track and the cursor log are
    /// timed from here, so they line up in the editor.
    private(set) var firstFrameTime: CMTime?

    init(url: URL, width: Int, height: Int, includeSystemAudio: Bool, includeMicrophone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        // HEVC keeps capture files small; export re-encodes to H.264 so
        // files play everywhere.
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = true

        if includeSystemAudio {
            let systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 2))
            systemAudio.expectsMediaDataInRealTime = true
            self.systemAudio = systemAudio
        } else {
            systemAudio = nil
        }

        if includeMicrophone {
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1))
            mic.expectsMediaDataInRealTime = true
            self.mic = mic
        } else {
            mic = nil
        }

        // Tracks are numbered in the order they are added, so the list
        // below is in the same order as the audio tracks in the file.
        let inputs: [(AVAssetWriterInput?, TakeAudioSource?)] = [(video, nil), (systemAudio, .system), (mic, .mic)]
        var audioTracks: [TakeAudioSource] = []
        for (input, source) in inputs {
            guard let input, writer.canAdd(input) else { continue }
            writer.add(input)
            if let source { audioTracks.append(source) }
        }
        // The take still records without the list: the transcriber then
        // tells the tracks apart by channel count (mic mono, system stereo).
        let take = Take(folder: url.deletingLastPathComponent())
        try? TakeAudioTracks(tracks: audioTracks).write(to: take.audioTracksURL)
    }

    /// The mic is always mono and system sound always stereo; the
    /// transcriber relies on this for takes without audio-tracks.json.
    private static func aac(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ]
    }

    func append(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit also sends "idle" buffers when nothing on
            // screen changed; only complete frames carry pixels.
            guard Self.isCompleteFrame(buffer) else { return }
            if firstFrameTime == nil {
                let time = buffer.presentationTimeStamp
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: time)
                firstFrameTime = time
            }
            if video.isReadyForMoreMediaData { video.append(buffer) }
        case .audio:
            if let systemAudio { appendAudio(buffer, to: systemAudio) }
        case .microphone:
            if let mic { appendAudio(buffer, to: mic) }
        @unknown default:
            break
        }
    }

    private func appendAudio(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        // Audio before the first frame would start the tracks out of sync.
        guard let firstFrameTime, buffer.presentationTimeStamp >= firstFrameTime else { return }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    /// Finishes the file. Returns false when no frame ever arrived.
    func finish() async -> Bool {
        guard writer.status == .writing else { return false }
        video.markAsFinished()
        systemAudio?.markAsFinished()
        mic?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    var error: Error? { writer.error }

    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}
