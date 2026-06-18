import Cocoa
import Carbon

final class HotkeyService {
    var onToggleRecording: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onPlaceMarker: (() -> Void)?
    var onQuickNote: (() -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    static var shared: HotkeyService?

    func startListening() {
        HotkeyService.shared = self

        // Install handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, nil)

        // Register hotkeys: ⌃⌥⌘ + key
        let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)

        // ID 1: ⌃⌥⌘R — toggle recording
        registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_R), modifiers: modifiers)
        // ID 2: ⌃⌥⌘P — pause/resume
        registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers)
        // ID 3: ⌃⌥⌘M — marker
        registerHotKey(id: 3, keyCode: UInt32(kVK_ANSI_M), modifiers: modifiers)
        // ID 4: ⌃⌥⌘N — quick note
        registerHotKey(id: 4, keyCode: UInt32(kVK_ANSI_N), modifiers: modifiers)
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        var hotKeyID = EventHotKeyID(signature: OSType(0x564D4252), id: id) // "VMBR"
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            hotKeyRefs.append(hotKeyRef)
        }
    }

    func handleHotKey(id: UInt32) {
        switch id {
        case 1: onToggleRecording?()
        case 2: onPauseResume?()
        case 3: onPlaceMarker?()
        case 4: onQuickNote?()
        default: break
        }
    }

    func stopListening() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
        HotkeyService.shared = nil
    }

    deinit {
        stopListening()
    }
}

private func hotKeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }

    DispatchQueue.main.async {
        HotkeyService.shared?.handleHotKey(id: hotKeyID.id)
    }
    return noErr
}
