import Foundation

/// What kind of camera a capture device is, so the picker can name it the
/// way people think of it and put the likely choice first.
public enum CameraKind: String, Codable, Sendable, CaseIterable {
    /// The Mac's own camera (FaceTime HD and friends).
    case builtIn
    /// An iPhone used through Continuity Camera, over USB or nearby.
    case iPhone
    /// The iPhone's Desk View: the ultra wide camera showing your desk.
    case deskView
    /// A USB or Thunderbolt webcam, capture card or virtual camera.
    case external

    public var detail: String {
        switch self {
        case .builtIn: return "Built into this Mac"
        case .iPhone: return "Continuity Camera"
        case .deskView: return "Shows your desk from above"
        case .external: return "Plugged in"
        }
    }

    /// Order in the picker: iPhone first because it's the best camera most
    /// people own, Desk View straight after it.
    var sortRank: Int {
        switch self {
        case .iPhone: return 0
        case .deskView: return 1
        case .builtIn: return 2
        case .external: return 3
        }
    }
}

/// A camera the Mac can see right now, as plain values so the choice logic
/// can be tested without AVFoundation.
public struct CameraInfo: Equatable, Sendable, Identifiable {
    /// AVCaptureDevice.uniqueID, stable across launches.
    public var id: String
    public var name: String
    public var kind: CameraKind
    /// For an iPhone camera, the uniqueID of its Desk View camera.
    public var deskViewID: String?

    public init(id: String, name: String, kind: CameraKind, deskViewID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.deskViewID = deskViewID
    }
}

/// Which camera the person wants. Auto follows macOS
/// (`AVCaptureDevice.systemPreferredCamera`), which switches to an iPhone
/// on a stand by itself. A manual pick sticks to that camera and is saved
/// as the user preferred camera, as Apple recommends for Continuity Camera.
public enum CameraChoice: Equatable, Codable, Sendable {
    case off
    case auto
    case device(id: String)

    /// The camera to record from. A manual pick that's been unplugged falls
    /// back to the system's pick, then to the first camera in picker order,
    /// so a missing iPhone never leaves a take without a camera.
    public func resolve(among cameras: [CameraInfo], systemPreferredID: String?) -> CameraInfo? {
        switch self {
        case .off:
            return nil
        case .device(let id):
            if let camera = cameras.first(where: { $0.id == id }) { return camera }
            fallthrough
        case .auto:
            if let id = systemPreferredID, let camera = cameras.first(where: { $0.id == id }) { return camera }
            return Self.pickerOrder(cameras).first { $0.kind != .deskView }
        }
    }

    /// Cameras sorted for the picker: iPhone, Desk View, built in, others,
    /// then by name.
    public static func pickerOrder(_ cameras: [CameraInfo]) -> [CameraInfo] {
        cameras.sorted {
            if $0.kind.sortRank != $1.kind.sortRank { return $0.kind.sortRank < $1.kind.sortRank }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// A plugged-in iPhone or iPad whose screen can be recorded over USB, the
/// way QuickTime Player does it.
public struct PhoneScreenInfo: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Whether to record a phone's screen into the take, and which one.
public enum PhoneScreenChoice: Equatable, Codable, Sendable {
    case off
    case device(id: String)

    /// The phone to record, or nil when it's off or unplugged. Unlike the
    /// camera there's no fallback: recording someone else's phone by
    /// surprise would be worse than recording none.
    public func resolve(among phones: [PhoneScreenInfo]) -> PhoneScreenInfo? {
        guard case .device(let id) = self else { return nil }
        return phones.first { $0.id == id }
    }
}
