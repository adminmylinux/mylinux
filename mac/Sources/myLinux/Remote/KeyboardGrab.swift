import AppKit

/// The "everything to the remote" keyboard mode: an HID-level event tap that swallows every key event while a
/// grabbing window is key and forwards it to that window's handler — so ⌘Tab, ⌘Space and the rest reach the remote.
/// Safety: the tap only forwards while `window` is key; it is removed when the window resigns key, the app
/// deactivates, the window closes, or the release combination (Ctrl+Option+G) is pressed; a watchdog checks every
/// second that the owning window is still key and alive, and macOS re-enables a tap it disabled for being slow.
/// The menu bar item (StatusMenu) is the way out with the mouse: its "Release Keyboard" calls `release()`, and while
/// its menu is open `passThrough` lets keys reach the menu instead of the remote.
final class KeyboardGrab {
    static let shared = KeyboardGrab()
    /// Posted on the main thread whenever the grab starts or stops (StatusMenu mirrors the state in its icon).
    static let changed = Notification.Name("KeyboardGrab.changed")
    private(set) weak var window: NSWindow?
    private var handler: ((NSEvent) -> Void)?
    private var keep: Set<String> = []
    private var tap: CFMachPort?
    private var watchdog: Timer?
    var isActive: Bool { tap != nil }
    var onRelease: (() -> Void)?
    /// While true every key goes to the Mac even though the tap is installed (the status menu is open).
    var passThrough = false

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
            guard !grab.passThrough, let win = grab.window, win.isKeyWindow, NSApp.isActive, let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
            // the release combination, and shortcuts the Mac keeps
            if type == .keyDown && ns.keyCode == 5 && ns.modifierFlags.contains(.control) && ns.modifierFlags.contains(.option) {
                DispatchQueue.main.async { grab.release() }; return nil
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
            if self.window == nil || !(self.window?.isKeyWindow ?? false) || !NSApp.isActive { self.release() }
        }
        NotificationCenter.default.post(name: KeyboardGrab.changed, object: self)
        return true
    }

    /// Ends the grab and tells the owner (the view shows the keys are back); what the release combination, the
    /// watchdog and the menu bar item do.
    func release() {
        guard isActive else { return }
        stop(); onRelease?()
    }

    func stop() {
        let was = isActive
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil; watchdog?.invalidate(); watchdog = nil; window = nil; handler = nil; passThrough = false
        if was { NotificationCenter.default.post(name: KeyboardGrab.changed, object: self) }
    }
}
