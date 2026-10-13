import AppKit
import Carbon.HIToolbox
import ShotateCore

/// System-wide shortcuts through RegisterEventHotKey. No Accessibility or Input Monitoring
/// permission is needed, and a registered shortcut never reaches the front app.
final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private static var shared: Hotkeys?

    init() {
        Hotkeys.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                if id.id == Hotkeys.pasteID { Hotkeys.shared?.onPaste() } else { Hotkeys.shared?.actions[id.id]?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// ⌘V, claimed only while a paste should ask which screenshot (see PastePicker). It is kept
    /// apart from the configured shortcuts, so reloading settings doesn't drop it.
    private static let pasteID: UInt32 = 0xFFFF
    private var pasteRef: EventHotKeyRef?
    var onPaste: () -> Void = {}

    var pasteClaimed: Bool { pasteRef != nil }

    func claimPaste(_ on: Bool) {
        if on, pasteRef == nil {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey), EventHotKeyID(signature: OSType(0x534E4150), id: Hotkeys.pasteID),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr { pasteRef = ref } else { NSLog("Shotate: couldn't claim ⌘V (status %d)", status) }
        } else if !on, let ref = pasteRef {
            UnregisterEventHotKey(ref)
            pasteRef = nil
        }
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    /// Returns false when another app already owns the shortcut.
    @discardableResult
    func register(_ shortcut: Shortcut, _ action: @escaping () -> Void) -> Bool {
        guard let code = Hotkeys.keyCodes[shortcut.key] else { return false }
        var mods = 0
        if shortcut.modifiers.contains(.cmd) { mods |= cmdKey }
        if shortcut.modifiers.contains(.shift) { mods |= shiftKey }
        if shortcut.modifiers.contains(.option) { mods |= optionKey }
        if shortcut.modifiers.contains(.control) { mods |= controlKey }
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: OSType(0x534E4150), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Shotate: shortcut %@ is taken (status %d)", shortcut.key, status)
            return false
        }
        refs.append(ref)
        actions[id] = action
        return true
    }

    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "space": kVK_Space, "return": kVK_Return, "escape": kVK_Escape, "tab": kVK_Tab,
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, k) in fkeys.enumerated() { m["f\(i + 1)"] = k }
        return m
    }()
}

extension Shortcut {
    /// For showing the shortcut next to a menu item.
    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.cmd) { f.insert(.command) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.control) { f.insert(.control) }
        return f
    }
}
