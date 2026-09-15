import AppKit

/// The launcher's item in the menu bar, there from launch. It is the way back to the Mac with the mouse when a
/// remote window has taken every key ("Everything to the remote"): the HID tap in KeyboardGrab swallows the
/// keyboard, but the menu bar still takes clicks, and while this menu is open keys reach the menu, not the remote.
/// The icon becomes a filled keyboard while a grab is on. The rest is convenience: the machines, Quit.
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    static let releaseTitle = "Release Keyboard to the Mac"
    private var item: NSStatusItem?
    private let menu = NSMenu()

    /// Puts the item in the menu bar; called once at launch.
    func install() {
        guard item == nil else { return }
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        i.behavior = []
        menu.delegate = self
        i.menu = menu
        item = i
        NotificationCenter.default.addObserver(self, selector: #selector(grabChanged), name: KeyboardGrab.changed, object: nil)
        grabChanged()
    }

    /// The menu as it is right now (rebuilt every time it opens, so it lists the current machines and windows).
    func makeMenu(into menu: NSMenu) {
        menu.removeAllItems()
        let grab = KeyboardGrab.shared
        let release = NSMenuItem(title: StatusMenu.releaseTitle, action: #selector(releaseKeyboard), keyEquivalent: "")
        release.target = self; release.isEnabled = grab.isActive
        release.toolTip = grab.isActive ? "Every key goes to \(grab.window?.title ?? "the remote") right now; Ctrl+Option+G does the same." : "No remote window holds the keyboard."
        menu.addItem(release)
        menu.addItem(.separator())
        let machines = NSMenuItem(title: "Machines…", action: #selector(showMachines), keyEquivalent: ""); machines.target = self
        menu.addItem(machines)
        let quick = NSMenuItem(title: "Quick Connect…", action: #selector(quickConnect), keyEquivalent: ""); quick.target = self
        menu.addItem(quick)
        let remotes = NSMenu()
        for p in RemoteStore.shared.profiles {
            let mi = NSMenuItem(title: p.title, action: #selector(openRemote(_:)), keyEquivalent: ""); mi.target = self; mi.representedObject = p.id
            mi.state = RemoteWindowController.open.contains { $0.profile.id == p.id } ? .on : .off
            remotes.addItem(mi)
        }
        if remotes.items.isEmpty { remotes.addItem(NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")) }
        let remoteItem = NSMenuItem(title: "Remote Machines", action: nil, keyEquivalent: ""); remoteItem.submenu = remotes
        menu.addItem(remoteItem)
        let close = NSMenuItem(title: "Close Remote Windows", action: #selector(closeRemotes), keyEquivalent: ""); close.target = self
        close.isEnabled = !RemoteWindowController.open.isEmpty
        menu.addItem(close)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit myLinux Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        menu.autoenablesItems = false
    }

    // ---- NSMenuDelegate: fresh items, and the keys go to the menu while it is open ----
    func menuNeedsUpdate(_ menu: NSMenu) { makeMenu(into: menu) }
    func menuWillOpen(_ menu: NSMenu) { KeyboardGrab.shared.passThrough = true }
    func menuDidClose(_ menu: NSMenu) { KeyboardGrab.shared.passThrough = false }

    @objc private func grabChanged() {
        let grabbing = KeyboardGrab.shared.isActive
        let button = item?.button
        button?.image = NSImage(systemSymbolName: grabbing ? "keyboard.fill" : "desktopcomputer", accessibilityDescription: "myLinux Launcher")
        button?.image?.isTemplate = true
        button?.toolTip = grabbing ? "myLinux Launcher: a remote window has every key. Open this menu to give them back." : "myLinux Launcher"
    }

    @objc private func releaseKeyboard() { KeyboardGrab.shared.release() }
    @objc private func quickConnect() { QuickConnect.shared.show() }

    /// Brings the machines window forward, reopening it when it was closed (as a click on the Dock icon would).
    @objc private func showMachines() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == "myLinux Machines" && $0.canBecomeKey }) { w.makeKeyAndOrderFront(nil); return }
        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
    }

    @objc private func openRemote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let p = RemoteStore.shared.profiles.first(where: { $0.id == id }) else { return }
        RemoteWindowController.show(p)
    }

    @objc private func closeRemotes() { RemoteWindowController.open.forEach { $0.window?.close() } }
}
