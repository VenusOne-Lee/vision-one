import Foundation

/// A mic the Mac can record from, reduced to what the panel and the
/// recorder need. `id` is AVCaptureDevice.uniqueID, which is what
/// SCStreamConfiguration.microphoneCaptureDeviceID takes.
public struct MicrophoneOption: Equatable, Sendable, Identifiable {
    public enum Transport: Sendable {
        case builtIn, bluetooth, usb, other
    }

    public let id: String
    public let name: String
    public let transport: Transport

    public init(id: String, name: String, transport: Transport) {
        self.id = id
        self.name = name
        self.transport = transport
    }

    /// Recording from a Bluetooth headset's mic switches the headset from
    /// music quality (A2DP) to call quality (HFP, 16 kHz mono), so what
    /// you're listening to changes the moment you press record.
    public var dropsHeadphonesToCallQuality: Bool { transport == .bluetooth }
}

public enum MicrophonePicker {
    /// The mic to record with. A saved pick wins while it's plugged in.
    /// Otherwise the Mac's default input, unless that is a Bluetooth
    /// headset: then the built-in mic, so the headphones keep playing in
    /// music quality. Falls back to any wired mic, then to the default.
    public static func pick(saved: String?, available: [MicrophoneOption], systemDefaultID: String?) -> MicrophoneOption? {
        if let saved, let chosen = available.first(where: { $0.id == saved }) {
            return chosen
        }
        let systemDefault = available.first { $0.id == systemDefaultID }
        if let systemDefault, !systemDefault.dropsHeadphonesToCallQuality {
            return systemDefault
        }
        return available.first { $0.transport == .builtIn }
            ?? available.first { !$0.dropsHeadphonesToCallQuality }
            ?? systemDefault
            ?? available.first
    }

    /// Built-in first, then wired, then Bluetooth, each by name.
    public static func menuOrder(_ options: [MicrophoneOption]) -> [MicrophoneOption] {
        func rank(_ transport: MicrophoneOption.Transport) -> Int {
            switch transport {
            case .builtIn: return 0
            case .usb: return 1
            case .other: return 2
            case .bluetooth: return 3
            }
        }
        return options.sorted {
            (rank($0.transport), $0.name.lowercased()) < (rank($1.transport), $1.name.lowercased())
        }
    }
}
