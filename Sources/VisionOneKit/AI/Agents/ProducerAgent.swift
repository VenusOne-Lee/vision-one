import Foundation

/// The Producer agent: a pre-flight check before recording, and an
/// optional outline of what to say. The checks are plain rules and run on
/// the Mac for free; only the outline uses the ladder.
public struct ProducerAgent: Sendable {
    /// What the app can see just before recording.
    public struct Situation: Equatable, Sendable {
        public var micName: String?
        /// Loudest mic level in the last second or two, in dBFS (0 is clipping).
        public var micPeakDB: Double?
        public var systemAudioOn: Bool
        public var cameraOn: Bool
        public var screenWidth: Int
        public var screenHeight: Int
        public var freeDiskGB: Double
        public var onBattery: Bool
        public var batteryPercent: Int?
        /// Nil when the app can't tell whether a Focus is on.
        public var notificationsSilenced: Bool?
        public var purposeID: String?

        public init(micName: String? = nil, micPeakDB: Double? = nil, systemAudioOn: Bool = true, cameraOn: Bool = false,
                    screenWidth: Int = 1920, screenHeight: Int = 1080, freeDiskGB: Double = 50,
                    onBattery: Bool = false, batteryPercent: Int? = nil, notificationsSilenced: Bool? = nil,
                    purposeID: String? = nil) {
            self.micName = micName
            self.micPeakDB = micPeakDB
            self.systemAudioOn = systemAudioOn
            self.cameraOn = cameraOn
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.freeDiskGB = freeDiskGB
            self.onBattery = onBattery
            self.batteryPercent = batteryPercent
            self.notificationsSilenced = notificationsSilenced
            self.purposeID = purposeID
        }
    }

    public struct Note: Equatable, Identifiable, Sendable {
        public enum Level: String, Sendable {
            /// Fix before recording, or the take won't work.
            case fix
            /// Worth a look; recording still works.
            case tip
        }

        public var id: String
        public var level: Level
        public var title: String
        public var detail: String
    }

    /// The pre-flight list, most important first. Empty means good to go.
    public static func check(_ s: Situation) -> [Note] {
        var notes: [Note] = []
        if s.micName == nil {
            notes.append(Note(id: "mic.none", level: .fix, title: "No microphone",
                              detail: "Pick a mic in the record picker, or your voice won't be in the take."))
        } else if let peak = s.micPeakDB {
            if peak < -45 {
                notes.append(Note(id: "mic.quiet", level: .fix, title: "Mic is very quiet",
                                  detail: "Say something: if the meter barely moves, check the mic or move closer."))
            } else if peak > -1 {
                notes.append(Note(id: "mic.loud", level: .tip, title: "Mic is clipping",
                                  detail: "Turn the input level down in System Settings → Sound, or sit back a little."))
            }
        }
        if s.freeDiskGB < 2 {
            notes.append(Note(id: "disk.low", level: .fix, title: "Almost out of space",
                              detail: String(format: "%.1f GB free. A 10-minute take needs about 2 GB.", s.freeDiskGB)))
        } else if s.freeDiskGB < 10 {
            notes.append(Note(id: "disk.tight", level: .tip, title: "Space is tight",
                              detail: String(format: "%.0f GB free, enough for a few short takes.", s.freeDiskGB)))
        }
        if s.onBattery, let pct = s.batteryPercent, pct < 20 {
            notes.append(Note(id: "battery.low", level: .tip, title: "Battery at \(pct)%",
                              detail: "Plug in so a long take doesn't stop halfway."))
        }
        if s.notificationsSilenced == false {
            notes.append(Note(id: "focus.off", level: .tip, title: "Notifications are on",
                              detail: "Turn on Do Not Disturb so pop-ups don't land in your video."))
        }
        let vertical = Purpose.named(s.purposeID ?? "")?.formats.first == "vertical"
        if vertical, s.screenWidth > s.screenHeight * 2 {
            notes.append(Note(id: "screen.wide", level: .tip, title: "Very wide screen for a vertical video",
                              detail: "Record one window or an area so the vertical crop can follow the action."))
        }
        if s.purposeID == "talkingHead", !s.cameraOn {
            notes.append(Note(id: "camera.off", level: .fix, title: "Camera is off",
                              detail: "A talking head video needs the camera bubble on."))
        }
        return notes.sorted { ($0.level == .fix ? 0 : 1) < ($1.level == .fix ? 0 : 1) }
    }

    /// Talking points: hook, context, payoff and call to action.
    public struct Outline: Codable, Equatable, Sendable {
        public var hook: String
        public var points: [String]
        public var payoff: String
        public var cta: String
    }

    public let ladder: AILadder

    public init(ladder: AILadder) {
        self.ladder = ladder
    }

    /// An outline from what the user says they're about to show. Short
    /// enough for the on-device model.
    public func outline(about topic: String, brief: AgentBrief) async throws -> Outline {
        let request = AIRequest(
            task: .producerOutline, summary: "Suggest talking points before recording",
            instructions: brief.instructions(
                "You help a builder plan a short screen recording. Suggest a hook, three to five points in order, the payoff, and a call to action. Plain words, no hype.",
                parts: ["hook", "outro"]),
            input: topic,
            format: .json(shape: #"{"hook": "...", "points": ["...", "..."], "payoff": "...", "cta": "..."}"#))
        return try await ladder.complete(request).decode(Outline.self)
    }
}
