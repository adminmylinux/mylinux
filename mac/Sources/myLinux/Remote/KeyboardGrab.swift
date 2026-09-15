import AppKit

/// The "everything to the remote" keyboard mode: an HID-level event tap that swallows every key event while a
/// grabbing window is key and forwards it to that window's handler — so ⌘Tab, ⌘Space and the rest reach the remote.
/// Safety: the tap only forwards while `window` is key; it is removed when the window resigns key, the app
/// deactivates, the window closes, or the release combination (Ctrl+Option+G) is pressed; a watchdog checks every
/// second that the owning window is still key and alive, and macOS re-enables a tap it disabled for being slow.
final class KeyboardGrab {
    static let shared = KeyboardGrab()
    private(set) weak var window: NSWindow?
    private var handler: ((NSEvent) -> Void)?
    private var keep: Set<String> = []
    private var tap: CFMachPort?
    private var watchdog: Timer?
    var isActive: Bool { tap != nil }
    var onRelease: (() -> Void)?

    static var permitted: Bool { AXIsProcessTrusted() }
    static func askPermission() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }

    /// Starts grabbing for `window`. `keep` lists shortcuts ("cmd+c") that stay with the Mac.
    func start(window: NSWindow, keep: [String], handler: @escaping (NSEvent) -> Void) -> Bool {
        stop()
        guard KeyboardGrab.permitted else { KeyboardGrab.askPermission(); return false }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
            let grab = Unmanaged<KeyboardGrab>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = grab.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
            guard let win = grab.window, win.isKeyWindow, NSApp.isActive, let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            // the release combination, and shortcuts the Mac keeps
            if type == .keyDown && ns.keyCode == 5 && ns.modifierFlags.contains(.control) && ns.modifierFlags.contains(.option) {
                DispatchQueue.main.async { grab.stop(); grab.onRelease?() }; return nil
            }
            if type != .flagsChanged, let name = KeyMap.shortcutName(ns), grab.keep.contains(name) { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { grab.handler?(ns) }
            return nil
        }, userInfo: me) else { return false }
        tap = t; self.window = window; self.handler = handler; self.keep = Set(keep.map { $0.lowercased() })
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.window == nil || !(self.window?.isKeyWindow ?? false) || !NSApp.isActive { self.stop(); self.onRelease?() }
        }
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil; watchdog?.invalidate(); watchdog = nil; window = nil; handler = nil
    }
}
