import AppKit
import SwiftUI

/// One remote connection in its own window; windows of this kind tab together (native macOS window tabs, so a tab
/// can be torn off, and each can go fullscreen on its own display). The toolbar carries the zoom (VNC) and the
/// keyboard mode; the HUD line under the picture shows the connection's numbers.
final class RemoteWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static var open: [RemoteWindowController] = []
    static var noPasswordHosts: Set<String> = []      // hosts that connected with an empty password this session: no prompt again
    static let trace: Any? = ProcessInfo.processInfo.environment["MYLINUX_TRACE"] == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { e in
        FileHandle.standardError.write("event \(e.type == .keyDown ? "key" : "click") window=\(e.window?.title ?? "none") key=\(NSApp.keyWindow?.title ?? "none") responder=\(String(describing: type(of: e.window?.firstResponder as Any)))\n".data(using: .utf8)!)
        return e
    }
    let profile: RemoteProfile
    private var vnc: VncConnection?
    private var vncView: VncView?
    private var ssh: SshTerminal?
    private let status = NSTextField(labelWithString: "")
    private let overlay = NSTextField(wrappingLabelWithString: "")
    private var hudTimer: Timer?
    private var lastUpdates = 0, lastDecode: UInt64 = 0
    private var pasteboardCount = 0
    private var keyboardMode: RemoteProfile.Keyboard

    /// Opens (or brings forward) the window for a profile.
    @discardableResult
    static func show(_ profile: RemoteProfile) -> RemoteWindowController {
        _ = trace
        if let existing = open.first(where: { $0.profile.id == profile.id }) { existing.window?.makeKeyAndOrderFront(nil); return existing }
        let c = RemoteWindowController(profile: profile)
        open.append(c); RemoteSession.noteOpenWindows()
        if let last = open.dropLast().last?.window, let w = c.window { last.addTabbedWindow(w, ordered: .above) }
        c.showWindow(nil); c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.connect()
        return c
    }

    init(profile: RemoteProfile) {
        self.profile = profile; keyboardMode = profile.keyboard
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = profile.title
        w.tabbingMode = .preferred; w.tabbingIdentifier = "myLinux Remote"
        w.collectionBehavior = [.fullScreenPrimary]
        w.center(); w.setFrameAutosaveName("remote-\(profile.id.uuidString)")
        super.init(window: w)
        w.delegate = self
        let root = NSView(frame: w.contentView!.bounds); root.autoresizingMask = [.width, .height]
        w.contentView = root
        status.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular); status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 8, y: 3, width: root.bounds.width - 16, height: 16); status.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(status)
        overlay.isHidden = true; overlay.alignment = .center; overlay.font = NSFont.systemFont(ofSize: 14)
        overlay.textColor = .white; overlay.backgroundColor = NSColor.black.withAlphaComponent(0.7); overlay.drawsBackground = true
        overlay.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(overlay)
        let toolbar = NSToolbar(identifier: "remote-\(profile.kind.rawValue)"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        w.toolbar = toolbar
    }
    required init?(coder: NSCoder) { fatalError() }

    private var contentArea: NSRect { NSRect(x: 0, y: 22, width: window!.contentView!.bounds.width, height: window!.contentView!.bounds.height - 22) }

    func connect() {
        guard let root = window?.contentView else { return }
        vncView?.removeFromSuperview(); ssh?.removeFromSuperview()
        if profile.kind == .vnc {
            let c = VncConnection(profile: profile)
            c.password = RemoteSecrets.password(for: profile) ?? ""
            let v = VncView(conn: c, keyboard: keyboardMode)
            v.frame = contentArea; v.autoresizingMask = [.width, .height]
            root.addSubview(v, positioned: .below, relativeTo: overlay)
            vnc = c; vncView = v
            c.onState = { [weak self] st in self?.stateChanged(st) }
            c.onServerText = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            v.onZoomChanged = { [weak self] in self?.window?.toolbar?.validateVisibleItems() }
            v.onGrabChanged = { [weak self] in self?.window?.toolbar?.validateVisibleItems(); self?.updateStatus() }
            window?.makeFirstResponder(v)
            // a saved password connects at once; otherwise ask (leave it empty for servers without a password)
            if !c.password.isEmpty || RemoteWindowController.noPasswordHosts.contains(profile.host) { c.start() }
            else { askPassword { pw in if pw.isEmpty { RemoteWindowController.noPasswordHosts.insert(self.profile.host) }; c.password = pw; c.start() } }
        } else {
            let t = SshTerminal(profile: profile)
            t.frame = contentArea; t.autoresizingMask = [.width, .height]
            root.addSubview(t, positioned: .below, relativeTo: overlay)
            ssh = t
            t.onExit = { [weak self] code in NSLog("remote %@: ssh exited %@", self?.profile.title ?? "", String(describing: code)); self?.showOverlay("Disconnected" + (code.map { $0 == 0 ? "" : " (ssh exited with status \($0))" } ?? "") + " — click to reconnect") }
            t.onTitle = { [weak self] title in self?.window?.title = title.isEmpty ? self?.profile.title ?? "" : "\(self?.profile.title ?? "") — \(title)" }
            window?.makeFirstResponder(t)
            t.start()
            status.stringValue = "ssh \(profile.username.isEmpty ? "" : profile.username + "@")\(profile.host):\(profile.port)" + (profile.tmux.isEmpty ? "" : "  tmux \(profile.tmux)")
        }
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatus() }
    }

    private func askPassword(_ then: @escaping (String) -> Void) {
        let alert = NSAlert(); alert.messageText = "Password for \(profile.username.isEmpty ? profile.host : profile.username + "@" + profile.host)"
        alert.informativeText = "Tick “Remember” to keep it in the Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); alert.accessoryView = field
        alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Remember in Keychain"
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { [self] r in
            guard r == .alertFirstButtonReturn else { showOverlay("Not connected — click to try again"); return }
            if alert.suppressionButton?.state == .on, RemoteSecrets.setPassword(field.stringValue, for: profile) {
                var p = profile; p.hasPassword = true; RemoteStore.shared.update(p)
            }
            then(field.stringValue)
        }
    }

    private func stateChanged(_ st: VncConnection.State) {
        FileHandle.standardError.write("remote \(profile.title) [\(ObjectIdentifier(vnc!).hashValue % 1000)]: \(String(describing: st).prefix(120))\n".data(using: .utf8)!)
        switch st {
        case .connecting: showOverlay("Connecting to \(profile.host):\(profile.port)…")
        case .connected:
            hideOverlay(); window?.toolbar?.validateVisibleItems()
            // test hook: MYLINUX_TEST_TYPE="text\n" is typed through the view's own key path 2 s after connecting
            if let text = ProcessInfo.processInfo.environment["MYLINUX_TEST_TYPE"], let v = vncView {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let (x, y) = (v.bounds.midX, v.bounds.midY)
                    let p = NSPoint(x: x, y: y)
                    for (down, type) in [(true, NSEvent.EventType.leftMouseDown), (false, .leftMouseUp)] {
                        if let e = NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: self.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: down ? 1 : 0) { if down { v.mouseDown(with: e) } else { v.mouseUp(with: e) } }
                    }
                    for ch in text {
                        let (chars, code): (String, UInt16) = ch == "\n" ? ("\r", 36) : (String(ch), 0)
                        for down in [true, false] {
                            if let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: self.window!.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { v.handle(e) }
                        }
                    }
                    FileHandle.standardError.write("test hook: typed \(text.count) characters\n".data(using: .utf8)!)
                }
            }
        case .failed(let m): showOverlay("Failed: \(m)\n(click to retry)")
        case .closed: showOverlay("Disconnected (click to reconnect)")
        case .untrusted(let info, let changed): trustSheet(info, changed: changed)
        case .idle: break
        }
        updateStatus()
    }

    private func trustSheet(_ info: CertPin.Info, changed: Bool) {
        let alert = NSAlert()
        alert.messageText = changed ? "The certificate of \(profile.host) has changed" : "First connection to \(profile.host): trust its certificate?"
        alert.informativeText = (changed ? "It no longer matches the certificate you trusted. That happens when wayvnc's certificate is regenerated, or when something else answers on this address.\n\n" : "The server uses a self-signed certificate. Compare the fingerprint with the server's (openssl x509 -noout -fingerprint -sha256 -in ~/.config/wayvnc/tls_cert.pem).\n\n")
            + "Name: \(info.name.isEmpty ? "(none)" : info.name)\nSHA-256: \(info.fingerprint)"
        alert.alertStyle = changed ? .critical : .informational
        alert.addButton(withTitle: changed ? "Replace and connect" : "Trust and connect"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [self] r in
            if r == .alertFirstButtonReturn { vnc?.trust() } else { showOverlay("Not connected — click to try again") }
        }
    }

    private func showOverlay(_ text: String) {
        overlay.stringValue = text; overlay.isHidden = false
        overlay.sizeToFit()
        let s = NSSize(width: overlay.frame.width + 40, height: overlay.frame.height + 24)
        overlay.frame = NSRect(x: (contentArea.width - s.width) / 2, y: contentArea.midY - s.height / 2, width: s.width, height: s.height)
    }
    private func hideOverlay() { overlay.isHidden = true }
    override func mouseDown(with e: NSEvent) {
        if !overlay.isHidden, overlay.frame.contains(window!.contentView!.convert(e.locationInWindow, from: nil)) { hideOverlay(); connect() }
        else { super.mouseDown(with: e) }
    }

    private func updateStatus() {
        guard let c = vnc, let v = vncView else { return }
        let u = c.updates - lastUpdates, d = Double(c.decodeNs - lastDecode) / 1e6
        lastUpdates = c.updates; lastDecode = c.decodeNs
        let mode = v.grabbing ? "all keys → remote (Ctrl+Option+G returns them)" : keyboardMode.title
        let lat = v.latencySamples > 0 ? String(format: "  key→picture %.0f ms", v.latencySum / Double(v.latencySamples)) : ""
        status.stringValue = c.width > 0 ? String(format: "%d×%d  %d%%  %d upd/s  decode %.0f ms/s%@  ·  %@", c.width, c.height, Int(v.displayScale * (window?.backingScaleFactor ?? 1) * 100), u, d, lat, mode) : mode
    }

    // ---- clipboard: what the Mac copies goes to the remote when the window becomes key ----
    func windowDidBecomeKey(_ n: Notification) {
        if let v = vncView { window?.makeFirstResponder(v) } else if let t = ssh { window?.makeFirstResponder(t) }
        let pb = NSPasteboard.general
        if pb.changeCount != pasteboardCount, let s = pb.string(forType: .string) { pasteboardCount = pb.changeCount; vnc?.send(text: s) }
        if let v = vncView, keyboardMode == .all, !v.grabbing { v.setGrab(true, keep: profile.keepForMac) }
    }
    func windowDidResignKey(_ n: Notification) { pasteboardCount = NSPasteboard.general.changeCount }
    func windowWillClose(_ n: Notification) {
        hudTimer?.invalidate(); vnc?.stop(); vncView?.setGrab(false, keep: [])
        RemoteWindowController.open.removeAll { $0 === self }
        RemoteSession.noteOpenWindows()             // closed on purpose: not brought back next time (unless quitting)
    }

    // ---- toolbar ----
    private enum Item: String, CaseIterable { case fit, zoomOut, zoomIn, pixels, keyboard, grab }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        let items: [Item] = profile.kind == .vnc ? [.fit, .zoomOut, .zoomIn, .pixels, .keyboard, .grab] : [.keyboard]
        return items.map { NSToolbarItem.Identifier($0.rawValue) } + [.flexibleSpace]
    }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let kind = Item(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id); item.target = self
        switch kind {
        case .fit: item.label = "Fit"; item.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Fit"); item.action = #selector(fit)
        case .zoomOut: item.label = "Zoom out"; item.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: nil); item.action = #selector(zoomOut)
        case .zoomIn: item.label = "Zoom in"; item.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil); item.action = #selector(zoomIn)
        case .pixels: item.label = "1:1"; item.image = NSImage(systemSymbolName: "1.magnifyingglass", accessibilityDescription: nil); item.action = #selector(pixels)
        case .grab: item.label = "Grab keys"; item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil); item.action = #selector(toggleGrab)
        case .keyboard:
            let menu = NSMenu()
            for m in RemoteProfile.Keyboard.allCases { let mi = NSMenuItem(title: m.title, action: #selector(pickKeyboard(_:)), keyEquivalent: ""); mi.target = self; mi.representedObject = m.rawValue; menu.addItem(mi) }
            let mi = NSMenuToolbarItem(itemIdentifier: id); mi.menu = menu; mi.label = "Keyboard"; mi.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            return mi
        }
        return item
    }
    @objc private func fit() { vncView?.zoom = 1 }
    @objc private func zoomOut() { vncView?.zoomStep(-1) }
    @objc private func zoomIn() { vncView?.zoomStep(1) }
    @objc private func pixels() { vncView?.zoomToPixels() }
    @objc private func toggleGrab() { guard let v = vncView else { return }; v.setGrab(!v.grabbing, keep: profile.keepForMac); if !v.grabbing && !KeyboardGrab.permitted { showOverlay("Grabbing every key needs Accessibility permission for myLinux Launcher (System Settings › Privacy & Security). Click to dismiss.") } }
    @objc private func pickKeyboard(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = RemoteProfile.Keyboard(rawValue: raw) else { return }
        keyboardMode = m; vncView?.keyboard = m
        var p = profile; p.keyboard = m; RemoteStore.shared.update(p)
        if m == .all { vncView?.setGrab(true, keep: profile.keepForMac) }
        updateStatus()
    }
    @objc func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }
}
