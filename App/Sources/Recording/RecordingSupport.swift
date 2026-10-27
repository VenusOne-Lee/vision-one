import AppKit
import AVFoundation
import Combine
import VisionOneKit

/// Seconds on the host clock, the one ScreenCaptureKit and the camera
/// stamp their buffers with, so pauses line up with every track.
enum HostClock {
    static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

/// The mic meter in the REC bar. Fed from the capture queue a few times a
/// second; the bar reads it on the main thread.
@MainActor
final class MicMonitor: ObservableObject {
    static let shared = MicMonitor()

    @Published private(set) var meter = MicLevelMeter()
    /// False when the take records no mic, so the bar hides the meter.
    @Published private(set) var isActive = false

    private init() {}

    func begin(withMicrophone: Bool) {
        meter = MicLevelMeter()
        isActive = withMicrophone
        if withMicrophone { meter.restartSilenceTimer(at: HostClock.now) }
    }

    func end() {
        isActive = false
        meter = MicLevelMeter()
    }

    func feed(peak: Double, at t: Double) {
        guard isActive else { return }
        meter.update(peak: peak, at: t)
    }

    /// After a pause, give the speaker a moment before warning again.
    func restartSilenceTimer() {
        meter.restartSilenceTimer(at: HostClock.now)
    }

    func isSilent(at t: Double = HostClock.now) -> Bool {
        isActive && meter.isSilent(at: t)
    }
}

/// Remembers the last app in front that wasn't Vision One, so pressing
/// record in the main window can hand the screen back to it.
@MainActor
final class FrontmostApp {
    static let shared = FrontmostApp()
    private(set) var lastOther: NSRunningApplication?
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated { FrontmostApp.shared.lastOther = app }
        }
    }
}

/// Puts Vision One's main window out of the way while recording, and
/// brings it back if the take is cancelled or deleted. (Its windows are
/// never in the video, but they'd still sit on top of what you show.)
@MainActor
enum MainWindowStepAside {
    private static var hidden: [NSWindow] = []

    static func hide() {
        hidden = NSApp.windows.filter { window in
            window.isVisible && !(window is NSPanel) && window.styleMask.contains(.titled)
        }
        guard !hidden.isEmpty else { return }
        hidden.forEach { $0.orderOut(nil) }
        if let other = FrontmostApp.shared.lastOther, !other.isTerminated {
            other.activate()
        }
    }

    /// The editor opens on stop, so after a saved take there's nothing
    /// to bring back.
    static func forget() {
        hidden = []
    }

    static func restore() {
        guard !hidden.isEmpty else { return }
        NSApp.activate()
        hidden.forEach { $0.makeKeyAndOrderFront(nil) }
        hidden = []
    }
}

extension ScreenRecorder {
    /// The display being recorded: the chosen one, or the one holding most
    /// of the window, or the main display.
    func recordedScreen() -> NSScreen {
        if choice.mode != .window, let id = choice.displayID,
           let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Reading and silencing audio sample buffers, for the meter and pause.
enum AudioSamples {
    /// The loudest sample in the buffer, 0...1, or nil if it can't be read.
    static func peak(of buffer: CMSampleBuffer) -> Double? {
        guard let format = buffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = description.mBitsPerChannel
        return try? buffer.withAudioBufferList { list, _ in
            var peak = 0.0
            for audio in list {
                guard let data = audio.mData else { continue }
                let bytes = Int(audio.mDataByteSize)
                if isFloat, bits == 32 {
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: bytes / 4)
                    peak = max(peak, MicLevelMeter.peak(ofFloats: samples))
                } else if !isFloat, bits == 16 {
                    let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: bytes / 2)
                    peak = max(peak, MicLevelMeter.peak(ofInt16: samples))
                }
            }
            return peak
        }
    }

    /// Zeroes the buffer's audio in place, so a pause leaves silence in
    /// the track instead of a hole. False if it couldn't be done.
    static func silence(_ buffer: CMSampleBuffer) -> Bool {
        guard let block = buffer.dataBuffer else { return false }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return false }
        return CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: length) == kCMBlockBufferNoErr
    }
}
