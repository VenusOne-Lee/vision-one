import Foundation

extension ExportPlanner {
    /// Encoder settings for a clip. Social apps re-encode whatever they
    /// get at their own fixed sizes, so clips always render at the
    /// format's full size and at most 30 fps, which phones play smoothly
    /// and which keeps the file small enough to send over mobile data.
    public static func settings(for format: ClipFormat, sourceFrameRate: Double, duration: Double) throws -> ExportSettings {
        guard duration > 0 else { throw ExportPlanError.emptyVideo }
        let size = format.size
        let rate = min(30, max(1, Int((sourceFrameRate > 0 ? sourceFrameRate : 30).rounded())))
        let bitRate = min(maxVideoBitRate, Int(Double(size.width * size.height * rate) * bitsPerPixel))
        return ExportSettings(width: size.width, height: size.height, frameRate: rate,
                              videoBitRate: bitRate, audioBitRate: 128_000, audioChannels: 2)
    }
}
