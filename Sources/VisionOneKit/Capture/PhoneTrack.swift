import Foundation

/// phone.json: how a plugged-in iPhone's recording (phone.mov) lines up
/// with screen.mov, so the editor and export can show the phone beside
/// the Mac. Both files run on the host clock and neither stops during a
/// pause (the paused stretch is cut in edits.json), so one offset is
/// enough.
public struct PhoneTrack: Codable, Equatable, Sendable {
    public var version = 1
    public var deviceName: String
    /// Seconds phone.mov started after screen.mov's first frame. Negative
    /// when the phone started first.
    public var startOffset: Double

    public init(deviceName: String, startOffset: Double) {
        self.deviceName = deviceName
        self.startOffset = startOffset
    }

    /// The moment of phone.mov that matches `t` seconds into screen.mov.
    public func phoneTime(forScreen t: Double) -> Double { t - startOffset }

    /// Share of the frame's height the phone takes.
    public static let heightShare = 0.72
    /// Gap from the frame's right edge, as a share of its height.
    public static let marginShare = 0.04
    /// Widest a sideways phone may be, as a share of the frame's width.
    public static let maximumWidthShare = 0.45

    /// Where the phone sits on a frame: on the right, centred top to
    /// bottom, keeping the phone's own shape (`aspect` is width over
    /// height of the phone's picture). Origin at the bottom left, like
    /// Core Image; the result is the same either way up.
    public static func frame(aspect: Double, in frame: CaptureRect) -> CaptureRect {
        guard aspect > 0, frame.width > 0, frame.height > 0 else {
            return CaptureRect(x: frame.x, y: frame.y, width: 0, height: 0)
        }
        var height = frame.height * heightShare
        var width = height * aspect
        let widest = frame.width * maximumWidthShare
        if width > widest {
            width = widest
            height = width / aspect
        }
        let margin = frame.height * marginShare
        return CaptureRect(x: frame.x + frame.width - margin - width,
                           y: frame.y + (frame.height - height) / 2,
                           width: width, height: height)
    }

    public static func read(from url: URL) throws -> PhoneTrack {
        try JSONDecoder().decode(PhoneTrack.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
