import Foundation

/// What the transcriber is doing. Shown as one muted line in the menu.
/// Never orange: only a live recording is orange.
public enum TranscriptionPhase: Equatable, Sendable {
    case idle
    /// First run only: the speech model is downloading. Progress 0...1.
    case downloadingModel(progress: Double?)
    case transcribing(takeName: String)
    case failed(takeName: String, message: String)

    public var isWorking: Bool {
        switch self {
        case .downloadingModel, .transcribing: return true
        case .idle, .failed: return false
        }
    }

    /// The menu line, or nil when there is nothing to say.
    public var statusText: String? {
        switch self {
        case .idle:
            return nil
        case let .downloadingModel(progress):
            guard let progress else { return "Getting the speech model…" }
            return "Getting the speech model… \(Int((min(max(progress, 0), 1) * 100).rounded()))%"
        case .transcribing:
            return "Writing the transcript…"
        case let .failed(_, message):
            return "No transcript yet. \(message)"
        }
    }
}

/// Collects decoded audio into one continuous run of samples, placing
/// each buffer at its timestamp. Gaps (a mic that dropped out) become
/// silence and overlaps are dropped, so sample n is always at n / rate
/// seconds from the take's first frame, and word times line up with the
/// video.
public struct SampleTimeline: Sendable {
    public let sampleRate: Double
    public private(set) var samples: [Float] = []
    /// How many samples the track actually gave, not counting the
    /// silence put in for gaps. A mic track that barely recorded has
    /// almost none, even when `samples` is long.
    public private(set) var decodedCount = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public var duration: Double { Double(samples.count) / sampleRate }
    /// Seconds of sound the track actually gave.
    public var decodedDuration: Double { Double(decodedCount) / sampleRate }

    public mutating func append(_ buffer: [Float], at seconds: Double) {
        decodedCount += buffer.count
        let position = Int((max(0, seconds) * sampleRate).rounded())
        if position > samples.count {
            samples.append(contentsOf: repeatElement(0, count: position - samples.count))
        }
        let skip = samples.count - position
        guard skip < buffer.count else { return }
        samples.append(contentsOf: buffer.dropFirst(skip))
    }
}

// MARK: - Which audio track to transcribe

/// A source of sound in screen.mov.
public enum TakeAudioSource: String, Codable, Sendable {
    case system
    case mic
}

/// audio-tracks.json: which source each audio track in screen.mov holds,
/// in track order. TakeWriter writes it when the take starts, so the
/// transcriber reads the mic and doesn't have to guess from how many
/// tracks there are.
public struct TakeAudioTracks: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// A mic track with less sound than this (seconds) is treated as
    /// empty, and system sound is transcribed instead when there is some.
    public static let minimumMicSeconds = 1.0

    public var version = TakeAudioTracks.currentVersion
    public var tracks: [TakeAudioSource]

    public init(tracks: [TakeAudioSource]) {
        self.tracks = tracks
    }

    public static func read(from url: URL) throws -> TakeAudioTracks {
        try JSONDecoder().decode(TakeAudioTracks.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Names the audio tracks found in screen.mov, given each track's
    /// channel count in track order. audio-tracks.json is used when it
    /// lists the same number of tracks. Otherwise (a take from before
    /// the file existed, or a track that never got any sound) the channel
    /// count decides: TakeWriter always encodes the mic as mono and
    /// system sound as stereo.
    public static func sources(recorded: TakeAudioTracks?, channelCounts: [Int]) -> [TakeAudioSource] {
        if let recorded, recorded.tracks.count == channelCounts.count { return recorded.tracks }
        return channelCounts.map { $0 == 1 ? .mic : .system }
    }

    /// True when the mic gave too little sound to transcribe and system
    /// sound gave more, so system sound should be used instead.
    public static func prefersSystem(micSeconds: Double, systemSeconds: Double) -> Bool {
        micSeconds < minimumMicSeconds && systemSeconds > micSeconds
    }
}

// MARK: - Failures

/// transcript-failed.json: written when a take can never be transcribed
/// (it has no sound), so the next launch doesn't try it again. Retrying
/// from the menu deletes it first.
public struct TranscriptFailure: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case noAudio
    }

    public var reason: Reason
    public var message: String
    public var createdAt: Date

    public init(reason: Reason, message: String, createdAt: Date = Date()) {
        self.reason = reason
        self.message = message
        self.createdAt = createdAt
    }

    public static func read(from url: URL) throws -> TranscriptFailure {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptFailure.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Failed takes and their messages, kept per take so a failure isn't
/// lost when the next take starts. The most recent one is shown in the
/// menu and is what Retry retries.
public struct TranscriptionFailures: Equatable, Sendable {
    public private(set) var messages: [String: String] = [:]
    /// Take names, oldest failure first.
    private var order: [String] = []

    public init() {}

    public var isEmpty: Bool { order.isEmpty }

    public subscript(takeName: String) -> String? { messages[takeName] }

    /// The newest failure still waiting for a retry.
    public var latest: (takeName: String, message: String)? {
        guard let name = order.last, let message = messages[name] else { return nil }
        return (name, message)
    }

    public mutating func record(_ message: String, for takeName: String) {
        order.removeAll { $0 == takeName }
        order.append(takeName)
        messages[takeName] = message
    }

    public mutating func clear(_ takeName: String) {
        order.removeAll { $0 == takeName }
        messages[takeName] = nil
    }
}

/// Failure messages that say how to fix, per docs/DESIGN.md.
public enum TranscriptionErrorText {
    public static let offline =
        "The speech model needs the internet once to download (about 0.5 GB). Connect and try again."
    public static let outOfSpace =
        "Your Mac is out of space. The speech model needs about 0.5 GB free. Free up some space and try again."
    public static let downloadFailed =
        "The speech model didn't finish downloading. Check your connection and try again."
    public static let busy =
        "Hugging Face, where the speech model comes from, is busy. Wait a few minutes and try again."

    public static func generic(_ error: Error) -> String {
        "Something went wrong (\(error.localizedDescription)). Try again."
    }

    /// A message for a network or full-disk error anywhere in the error's
    /// underlying-error chain, or nil when there is none.
    public static func message(forUnderlying error: Error) -> String? {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSURLErrorDomain { return offline }
            if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
                return outOfSpace
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return outOfSpace }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
