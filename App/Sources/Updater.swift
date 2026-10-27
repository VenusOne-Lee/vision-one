import AppKit
import Sparkle

/// Sparkle updates. Release builds carry the appcast's public key and
/// check once a day; dev builds have no key, so they never check.
///
/// Vision One is a menu bar app, so a scheduled update shouldn't pop a
/// window over whatever the builder is recording. Sparkle's "gentle
/// reminders" let the menu show "Update to x.y" instead, and the window
/// opens when they click it.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// The version a scheduled check found, until the builder looks at it.
    @Published private(set) var waitingVersion: String?

    private var controller: SPUStandardUpdaterController?

    var isEnabled: Bool { controller != nil }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func start() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard controller == nil, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Show Sparkle's window straight away only when Vision One is in front.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { waitingVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { waitingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waitingVersion = nil }
    }
}
