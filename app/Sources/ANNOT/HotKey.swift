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
/// A global NSEvent monitor added before Accessibility is on stays deaf until ANNOT restarts, so this uses an event
/// tap: it can't be created without the permission, so `start` keeps trying every second and works once it's granted.
final class DoubleTap {
    static var onPress: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var downAt: TimeInterval = 0
    private var lastTap: TimeInterval = 0
    private var clean = false // ⌥ is down alone

    func start() {
        guard tap == nil, retry == nil, !install() else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, self.install() else { return }
            t.invalidate()
            self.retry = nil
        }
    }

    func stop() {
        retry?.invalidate()
        retry = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// A listen-only tap on the session's events, ANNOT's own windows included. Only with Accessibility: before
    /// that, trying would make macOS ask for Input Monitoring instead.
    private func install() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, me in
                                              if let me { Unmanaged<DoubleTap>.fromOpaque(me).takeUnretainedValue().handle(type, event) }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        (self.tap, self.source) = (tap, source)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if let e = NSEvent(cgEvent: event) { handle(e) }
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
