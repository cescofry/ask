import Carbon
import Foundation

// ---------------------------------------------------------------------------
// Global hotkey registration using Carbon APIs
// ---------------------------------------------------------------------------

/// Signature used to identify our hotkey with the Carbon event system.
private let hotKeySignature: UInt32 = {
    let chars: [UInt8] = [
        UInt8(ascii: "A"), UInt8(ascii: "S"), UInt8(ascii: "K"), UInt8(ascii: "W"),
    ]
    return UInt32(chars[0]) << 24 | UInt32(chars[1]) << 16 | UInt32(chars[2]) << 8
        | UInt32(chars[3])
}()

private var hotKeyRef: EventHotKeyRef?

/// Callback invoked by the Carbon event system when the hotkey is pressed.
private var hotKeyHandler: (() -> Void)?

/// Register a global hotkey from a `ParsedShortcut`.
/// The `handler` closure is called on every keypress, on the main thread.
func registerGlobalHotKey(shortcut: ParsedShortcut, handler: @escaping () -> Void) -> Bool {
    hotKeyHandler = handler

    // Install Carbon event handler
    var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )

    let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
        guard let event = event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return status }

        if hotKeyID.signature == hotKeySignature {
            DispatchQueue.main.async {
                hotKeyHandler?()
            }
        }
        return noErr
    }

    var handlerRef: EventHandlerRef?
    let installStatus = InstallEventHandler(
        GetApplicationEventTarget(),
        callback,
        1,
        &eventType,
        nil,
        &handlerRef
    )
    guard installStatus == noErr else { return false }

    // Register the hotkey
    let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
    let registerStatus = RegisterEventHotKey(
        shortcut.keyCode,
        shortcut.modifiers,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &hotKeyRef
    )
    return registerStatus == noErr
}

/// Unregister the previously registered global hotkey.
func unregisterGlobalHotKey() {
    if let ref = hotKeyRef {
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
    }
}
