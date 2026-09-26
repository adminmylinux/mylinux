import AppKit

/// ⌘Space in a Debian or Alpine window opens Find and Run, as Super+Space does in Omarchy, instead of Spotlight.
/// macOS gives ⌘Space to Spotlight before any app sees it, so the launcher (which has the Accessibility permission
/// for Omarchy's "every key" mode) keeps an HID-level event tap that takes ⌘Space, and only ⌘Space, while the front
/// window is a server's terminal: a machine's own app (MachineApp: the launcher tells it, MachineLink.palette) or
/// one of the launcher's own terminal windows. Anywhere else ⌘Space is Spotlight's as always. Without the
/// permission there is no tap and ⌥Space does the same. Settings › Terminal turns it off.
final class SpaceHotkey {
    static let shared = SpaceHotkey()
    static let settingKey = "cmdSpaceFindAndRun"
    private var tap: CFMachPort?
    private var retry: Timer?
    /// the keyDown was taken: its keyUp is taken too
    private var swallowUp = false

    static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
    var isActive: Bool { tap != nil }

    /// At launch, and when the setting changes: the tap while enabled and permitted; without the permission yet,
    /// it is tried again every 10 s, so granting it in System Settings is enough.
    func update() {
        guard !MachineApp.active else { return }
        if !SpaceHotkey.enabled { stop(); return }
        guard tap == nil else { return }
        if AXIsProcessTrusted() { install() }
        else if retry == nil {
            retry = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                if AXIsProcessTrusted() || !SpaceHotkey.enabled { self?.retry?.invalidate(); self?.retry = nil; self?.update() }
            }
        }
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil; retry?.invalidate(); retry = nil
    }

    private func install() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
            let hk = Unmanaged<SpaceHotkey>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = hk.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard event.getIntegerValueField(.keyboardEventKeycode) == 49 else { return Unmanaged.passUnretained(event) }   // Space
            if type == .keyUp {
                if hk.swallowUp { hk.swallowUp = false; return nil }
                return Unmanaged.passUnretained(event)
            }
            let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            guard mods == .maskCommand, let target = SpaceHotkey.target() else { return Unmanaged.passUnretained(event) }
            hk.swallowUp = true
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }     // held down: opened once
            DispatchQueue.main.async { SpaceHotkey.open(target) }
            return nil
        }, userInfo: me) else { NSLog("⌘Space: the event tap could not be made"); return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        NSLog("⌘Space: Find and Run in the servers' windows")
    }

    enum Target { case machineApp(UUID), window(RemoteWindowController) }

    /// Whose ⌘Space this is: the front app is a server's own app, or the launcher with a server's terminal window
    /// in front. Nil for everything else (Spotlight's).
    static func target(front: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Target? {
        guard let app = front, let id = app.bundleIdentifier else { return nil }
        let prefix = "dev.mylinux.machine."
        if id.hasPrefix(prefix), let machine = UUID(uuidString: String(id.dropFirst(prefix.count))) { return .machineApp(machine) }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let c = NSApp.keyWindow?.windowController as? RemoteWindowController, c.profile.launcherMachine { return .window(c) }
        return nil
    }

    static func open(_ target: Target) {
        switch target {
        case .machineApp(let id): MachineLink.post(MachineLink.palette, ["id": id.uuidString])
        case .window(let c): c.showPalette()
        }
    }
}
