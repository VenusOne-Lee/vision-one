import Carbon.HIToolbox
import Combine

/// Registers ⌘⇧R as a system-wide shortcut with the Carbon hot key API,
/// which needs no Accessibility permission. `isRegistered` says whether
/// it took, so the panel can say when another app already owns ⌘⇧R.
final class GlobalHotKey: ObservableObject {
    static let shared = GlobalHotKey()

    @Published private(set) var isRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_R),
                  modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                  action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.action?()
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5649_4F4E), id: 1) // "VION"
        // Exclusive, so it fails (instead of silently never firing) when
        // another app already holds the same keys.
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &hotKeyRef)
        isRegistered = status == noErr && hotKeyRef != nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
