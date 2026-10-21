import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon (APP-1). Needs no Accessibility permission.
final class HotKey {
    static var onPress: (() -> Void)?
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    func register(_ combo: HotKeyCombo) {
        unregister()
        if !Self.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            Self.handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x414E_4E54), id: 1) // 'ANNT'
        RegisterEventHotKey(combo.code, combo.mods, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    // MARK: recording helpers

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func label(_ f: NSEvent.ModifierFlags, key: String) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + key
    }

    static func keyName(_ e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        default: return (e.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// Double-tap ⌥: two quick taps of Option with nothing else pressed. Watching other apps' keys needs Accessibility.
final class DoubleTap {
    static var onPress: (() -> Void)?
    private var monitors: [Any] = []
    private var downAt: TimeInterval = 0
    private var lastTap: TimeInterval = 0
    private var clean = false // ⌥ is down alone

    func start() {
        guard monitors.isEmpty else { return }
        let types: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] e in self?.handle(e) },
            NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] e in self?.handle(e); return e }, // our own windows
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ e: NSEvent) {
        guard e.type == .flagsChanged else { clean = false; lastTap = 0; return } // a key or click in between: no tap
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        if flags == .option {
            downAt = e.timestamp
            clean = true
        } else if flags.isEmpty, clean, e.timestamp - downAt < 0.35 { // released quickly: one tap
            clean = false
            if e.timestamp - lastTap < 0.45 { lastTap = 0; Self.onPress?() } else { lastTap = e.timestamp }
        } else {
            clean = false
            lastTap = 0
        }
    }
}
