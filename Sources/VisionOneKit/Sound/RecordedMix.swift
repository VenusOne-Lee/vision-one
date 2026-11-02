import Foundation

/// Saved source levels. Mute/solo in LaneMix remains a listening aid;
/// these levels are the mix both playback and export use.
public struct RecordedMix: Codable, Equatable, Sendable {
    public var voiceDB: Double
    public var systemDB: Double
    public init(voiceDB: Double = 0, systemDB: Double = 0) {
        self.voiceDB = voiceDB
        self.systemDB = systemDB
    }
    public func gain(isMicrophone: Bool) -> Float {
        let db = isMicrophone ? voiceDB : systemDB
        guard db.isFinite else { return 1 }
        return Float(pow(10, min(6, max(-60, db)) / 20))
    }
    public static func load(for take: Take) -> RecordedMix {
        guard let data = try? Data(contentsOf: take.recordedMixURL),
              let mix = try? JSONDecoder().decode(Self.self, from: data) else { return RecordedMix() }
        return mix
    }
    public func write(for take: Take) throws {
        try JSONEncoder().encode(self).write(to: take.recordedMixURL, options: .atomic)
    }
}
extension Take {
    public var recordedMixURL: URL { folder.appendingPathComponent("recorded-mix.json") }
}
