import Carbon.HIToolbox
import Combine

/// Registers system-wide shortcuts with the Carbon hot key API, which
/// needs no Accessibility permission: ⌘⇧R to start or stop, and ⌥⇧P to
/// pause or resume (Loom's pause keys). `isRegistered` says whether ⌘⇧R
/// took, so the panel can say when another app already owns it.
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()

    @Published private(set) var isRegistered = false
    @Published private(set) var isPauseRegistered = false

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    private static let signature = OSType(0x5649_4F4E) // "VION"
    private static let recordID: UInt32 = 1
    private static let pauseID: UInt32 = 2

    /// ⌘⇧R by default.
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_R),
                  modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                  action: @escaping () -> Void) {
        isRegistered = add(id: Self.recordID, keyCode: keyCode, modifiers: modifiers, action: action)
    }

    /// ⌥⇧P. ⌘⇧P belongs to too many apps' command palettes to take.
    func registerPause(action: @escaping () -> Void) {
        isPauseRegistered = add(id: Self.pauseID, keyCode: UInt32(kVK_ANSI_P),
                                modifiers: UInt32(optionKey | shiftKey), action: action)
    }

    private func add(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandler()
        actions[id] = action
        var ref: EventHotKeyRef?
        // Exclusive, so it fails (instead of silently never firing) when
        // another app already holds the same keys.
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs.append(ref)
        return true
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.actions[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
    }

    deinit {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
