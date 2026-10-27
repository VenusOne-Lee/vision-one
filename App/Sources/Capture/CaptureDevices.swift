import AVFoundation
import CoreMediaIO
import VisionOneKit

/// The cameras and plugged-in iPhones the Mac can record from, and which
/// ones the person picked. An iPhone shows up here two ways:
/// - as a camera, through Continuity Camera (plus its Desk View), and
/// - as a screen, when plugged in with USB, the way QuickTime records it.
/// Choices are saved, and a manual camera pick is handed to macOS as the
/// user preferred camera, as Apple recommends for Continuity Camera.
@MainActor
final class CaptureDevices: ObservableObject {
    static let shared = CaptureDevices()

    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var phones: [PhoneScreenInfo] = []
    @Published private(set) var systemPreferredCameraID: String?

    @Published var cameraChoice: CameraChoice {
        didSet { choiceChanged(old: oldValue) }
    }
    @Published var phoneChoice: PhoneScreenChoice {
        didSet { Self.save(phoneChoice, key: Self.phoneKey); if phoneChoice != .off { requestVideoAccess() } }
    }

    private static let cameraKey = "captureCameraChoice"
    private static let phoneKey = "capturePhoneScreenChoice"
    private var observers: [NSObjectProtocol] = []
    private var systemObserver: SystemCameraObserver?

    private init() {
        cameraChoice = Self.load(CameraChoice.self, key: Self.cameraKey) ?? .off
        phoneChoice = Self.load(PhoneScreenChoice.self, key: Self.phoneKey) ?? .off
        Self.allowPhoneScreens()
        refresh()

        // A phone's screen appears a moment after the opt-in above, and
        // iPhones come and go, so list again whenever a device does.
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        systemObserver = SystemCameraObserver { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        cameras = Self.cameraDevices().map(Self.info(for:))
        phones = Self.phoneDevices().map { PhoneScreenInfo(id: $0.uniqueID, name: $0.localizedName) }
        systemPreferredCameraID = AVCaptureDevice.systemPreferredCamera?.uniqueID
    }

    /// Cameras in picker order: iPhone, Desk View, this Mac, others.
    var pickerCameras: [CameraInfo] { CameraChoice.pickerOrder(cameras) }

    /// The camera to record from for the current choice, if any.
    func cameraToRecord() -> AVCaptureDevice? {
        guard let info = cameraChoice.resolve(among: cameras, systemPreferredID: systemPreferredCameraID) else { return nil }
        return AVCaptureDevice(uniqueID: info.id)
    }

    /// The plugged-in phone to record, if one is chosen and still there.
    func phoneToRecord() -> AVCaptureDevice? {
        guard let info = phoneChoice.resolve(among: phones) else { return nil }
        return AVCaptureDevice(uniqueID: info.id)
    }

    /// Short label for the menu: "Off", "Auto · FaceTime HD Camera", "Lee's iPhone".
    var cameraLabel: String {
        switch cameraChoice {
        case .off: return "Off"
        case .auto:
            let current = cameraChoice.resolve(among: cameras, systemPreferredID: systemPreferredCameraID)
            return current.map { "Auto · \($0.name)" } ?? "Auto"
        case .device(let id):
            return cameras.first { $0.id == id }?.name ?? "Not connected"
        }
    }

    var phoneLabel: String {
        switch phoneChoice {
        case .off: return "Off"
        case .device(let id): return phones.first { $0.id == id }?.name ?? "Plug in with USB"
        }
    }

    var hasVideoAccess: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    // MARK: Private

    private func choiceChanged(old: CameraChoice) {
        Self.save(cameraChoice, key: Self.cameraKey)
        if case .device(let id) = cameraChoice, let device = AVCaptureDevice(uniqueID: id) {
            AVCaptureDevice.userPreferredCamera = device
        }
        if cameraChoice != .off { requestVideoAccess() }
    }

    private func requestVideoAccess() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { _ in
            Task { @MainActor in CaptureDevices.shared.refresh() }
        }
    }

    private static func cameraDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .deskViewCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.filter { !$0.hasMediaType(.muxed) }
    }

    /// iPhones and iPads plugged in with USB show up as muxed (video and
    /// sound) devices once screen capture devices are allowed.
    private static func phoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices
    }

    private static func info(for device: AVCaptureDevice) -> CameraInfo {
        let kind: CameraKind
        switch device.deviceType {
        case .continuityCamera: kind = .iPhone
        case .deskViewCamera: kind = .deskView
        case .builtInWideAngleCamera: kind = .builtIn
        default: kind = .external
        }
        return CameraInfo(id: device.uniqueID, name: device.localizedName, kind: kind,
                          deskViewID: device.companionDeskViewCamera?.uniqueID)
    }

    /// Lets AVFoundation see plugged-in iOS devices' screens. QuickTime
    /// Player and OBS do the same.
    private static func allowPhoneScreens() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Watches the class property `AVCaptureDevice.systemPreferredCamera`,
/// which changes when macOS switches to an iPhone on a stand. Key paths
/// can't name class properties, so this uses string KVO on the class.
private final class SystemCameraObserver: NSObject {
    private static let keyPath = "systemPreferredCamera"
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: Self.keyPath, options: [.new], context: nil)
    }

    deinit {
        (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: Self.keyPath)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        onChange()
    }
}
