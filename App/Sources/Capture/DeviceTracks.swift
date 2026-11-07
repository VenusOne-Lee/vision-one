import AVFoundation
import VisionOneKit

/// Starts and stops the device tracks of a take. Today that's a plugged-in
/// iPhone's screen and sound (phone.mov); the camera bubble records
/// camera.mov itself and picks its camera from `CaptureDevices`. Tracks
/// are extras: if one can't start, the screen recording carries on and
/// the menu says why.
@MainActor
final class DeviceTracks {
    private var recorders: [DeviceTrackRecorder] = []
    private var phoneInfoURL: URL?

    /// Returns a note for each track that couldn't start.
    func start(for take: Take, devices: CaptureDevices) async -> [String] {
        var notes: [String] = []
        phoneInfoURL = take.phoneInfoURL
        let wanted: [(device: AVCaptureDevice?, url: URL, what: String, chosen: Bool)] = [
            (devices.phoneToRecord(), take.phoneURL, "iPhone screen", devices.phoneChoice != .off),
        ]
        for track in wanted where track.chosen {
            guard devices.hasVideoAccess else {
                notes.append("Recording without the \(track.what): turn on Camera access for Vision One in System Settings → Privacy & Security → Camera.")
                continue
            }
            guard let device = track.device else {
                notes.append("Recording without the \(track.what): it isn't connected.")
                continue
            }
            do {
                let recorder = try DeviceTrackRecorder(device: device, url: track.url)
                try await recorder.start()
                recorders.append(recorder)
            } catch {
                notes.append("Recording without the \(track.what): \(error.localizedDescription)")
            }
        }
        return notes
    }

    /// Finishes every track. With `screenStart` (screen.mov's first frame
    /// on the host clock) the phone's phone.json is written, so the editor
    /// and export can line phone.mov up; without it the take is going away.
    func stop(screenStart: Double? = nil) async {
        for recorder in recorders {
            let failed = await recorder.stop()
            guard failed == nil, let screenStart, let startedAt = recorder.startedAt,
                  let infoURL = phoneInfoURL, recorder.url.lastPathComponent == "phone.mov" else { continue }
            try? PhoneTrack(deviceName: recorder.deviceName, startOffset: startedAt - screenStart).write(to: infoURL)
        }
        recorders = []
        phoneInfoURL = nil
    }
}
