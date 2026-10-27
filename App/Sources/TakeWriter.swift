import AVFoundation
import ScreenCaptureKit

/// Writes ScreenCaptureKit's sample buffers to screen.mov with one video
/// track and separate system sound and mic tracks. The file is written
/// in fragments every 2 seconds, so a crash loses seconds, not the take.
///
/// Used only from the capture queue, so it needs no locking.
final class TakeWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput
    /// Nil when Microphone access is off; the take then has no mic track.
    private let mic: AVAssetWriterInput?

    /// Host time of the first frame. Every track and the cursor log are
    /// timed from here, so they line up in the editor.
    private(set) var firstFrameTime: CMTime?

    init(url: URL, width: Int, height: Int, includeMicrophone: Bool) throws {
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

        systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 2))
        systemAudio.expectsMediaDataInRealTime = true

        if includeMicrophone {
            let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1))
            mic.expectsMediaDataInRealTime = true
            self.mic = mic
        } else {
            mic = nil
        }

        for input in [video, systemAudio, mic].compactMap({ $0 }) where writer.canAdd(input) {
            writer.add(input)
        }
    }

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
            appendAudio(buffer, to: systemAudio)
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
        systemAudio.markAsFinished()
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
