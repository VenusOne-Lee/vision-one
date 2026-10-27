import AVFoundation
import CoreAudio
import VisionOneKit

/// The mics plugged in right now, kept current as they come and go, so
/// the panel can name the one in use and the recorder can pick it.
@MainActor
final class Microphones: ObservableObject {
    static let shared = Microphones()

    @Published private(set) var options: [MicrophoneOption] = []
    @Published private(set) var systemDefaultID: String?

    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in Microphones.shared.refresh() }
            })
        }
    }

    func refresh() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        var seen = Set<String>()
        let found = devices.compactMap { device -> MicrophoneOption? in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return MicrophoneOption(id: device.uniqueID, name: device.localizedName,
                                    transport: Self.transport(of: device))
        }
        options = MicrophonePicker.menuOrder(found)
        systemDefaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// The mic a take with this choice records from.
    func resolved(for choice: CaptureChoice) -> MicrophoneOption? {
        MicrophonePicker.pick(saved: choice.microphoneID, available: options, systemDefaultID: systemDefaultID)
    }

    private static func transport(of device: AVCaptureDevice) -> MicrophoneOption.Transport {
        switch UInt32(bitPattern: device.transportType) {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }
}
