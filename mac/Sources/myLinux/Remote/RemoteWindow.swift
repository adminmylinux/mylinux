import AppKit
import SwiftUI

/// One remote connection in its own window; windows of this kind tab together (native macOS window tabs, so a tab
/// can be torn off, and each can go fullscreen on its own display). The toolbar carries the zoom (VNC) and the
/// keyboard mode; the HUD line under the picture shows the connection's numbers.
final class RemoteWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    static var open: [RemoteWindowController] = []
    static var noPasswordHosts: Set<String> = []      // hosts that connected with an empty password this session: no prompt again
    static let trace: Any? = ProcessInfo.processInfo.environment["MYLINUX_TRACE"] == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { e in
        FileHandle.standardError.write("event \(e.type == .keyDown ? "key" : "click") window=\(e.window?.title ?? "none") key=\(NSApp.keyWindow?.title ?? "none") responder=\(String(describing: type(of: e.window?.firstResponder as Any)))\n".data(using: .utf8)!)
        return e
    }
    let profile: RemoteProfile
    private var vnc: VncConnection?
    private var vncView: VncView?
    /// The terminals of this tab. `ssh` is the one with the keyboard (or the first), which the actions type into.
    private var terminals: [SshTerminal] = []
    private var ssh: SshTerminal? {
        if let t = window?.firstResponder as? SshTerminal, terminals.contains(where: { $0 === t }) { return t }
        return terminals.first
    }
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
        if profile.launcherMachine {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.window === self.window, e.keyCode == 36 else { return e }      // 36: Return
                let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
                if mods == [.command] { self.splitTerminal(); return nil }
                if mods == [.command, .shift] { self.showBrowserAndFocus(); return nil }
                return e
            }
            // ⌘T: another tab to the same machine (the terminal keeps ⌘ combinations for the Mac)
            keyMonitorT = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.window === self.window, e.charactersIgnoringModifiers == "t",
                      e.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command] else { return e }
                self.newTerminal(); return nil
            }
        }
        let toolbar = NSToolbar(identifier: "remote-\(profile.kind.rawValue)\(profile.launcherMachine ? "-machine" : "")"); toolbar.delegate = self; toolbar.displayMode = .iconOnly
        if profile.launcherMachine { toolbar.centeredItemIdentifiers = [NSToolbarItem.Identifier(Item.mylinux.rawValue)] }
        w.toolbar = toolbar
    }
    required init?(coder: NSCoder) { fatalError() }

    private var contentArea: NSRect { NSRect(x: 0, y: 22, width: window!.contentView!.bounds.width, height: window!.contentView!.bounds.height - 22) }
    /// The terminals' place: inset from the window's edges, so the first column is not against the rounded frame.
    private var terminalRect: NSRect { contentArea.insetBy(dx: 6, dy: 0) }
    private var browser: BrowserPane?
    private var tunnel: SocksTunnel?
    private var forwards: [Int: PortForward] = [:]
    private var keyMonitor: Any?
    private var keyMonitorT: Any?
    /// terminals | browser
    private var outer: NSSplitView?
    /// the terminals: columns while the tab is terminals only, a stack on the left once the browser is there
    private var terminalArea: NSSplitView?

    func connect() {
        guard let root = window?.contentView else { return }
        vncView?.removeFromSuperview(); outer?.removeFromSuperview(); terminals.removeAll(); outer = nil; terminalArea = nil
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
            let o = NSSplitView(frame: terminalRect); o.isVertical = true; o.dividerStyle = .thin; o.autoresizingMask = [.width, .height]
            let area = NSSplitView(frame: o.bounds); area.isVertical = true; area.dividerStyle = .thin
            o.addArrangedSubview(area)
            root.addSubview(o, positioned: .below, relativeTo: overlay)
            outer = o; terminalArea = area
            let t = makeTerminal()
            area.addArrangedSubview(t)
            window?.makeFirstResponder(t)
            status.stringValue = "ssh \(profile.username.isEmpty ? "" : profile.username + "@")\(profile.host):\(profile.port)" + (profile.tmux.isEmpty ? "" : "  tmux \(profile.tmux)")
        }
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatus() }
    }

    /// A terminal to the machine, started; it leaves the tab on its own when its shell ends and others remain.
    private func makeTerminal() -> SshTerminal {
        let t = SshTerminal(profile: profile)
        t.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        terminals.append(t)
        if profile.launcherMachine { t.onOpenLink = { [weak self] url in self?.openInBrowser(url) } }
        t.onExit = { [weak self, weak t] code in
            guard let self, let t else { return }
            NSLog("remote %@: ssh exited %@", self.profile.title, String(describing: code))
            if self.terminals.count > 1 { self.remove(terminal: t); return }
            self.showOverlay("Disconnected" + (code.map { $0 == 0 ? "" : " (ssh exited with status \($0))" } ?? "") + " — click to reconnect")
        }
        t.onTitle = { [weak self, weak t] title in
            guard let self, self.ssh === t else { return }
            self.window?.title = title.isEmpty ? self.profile.title : "\(self.profile.title) — \(title)"
        }
        t.start()
        return t
    }
    private func remove(terminal t: SshTerminal) {
        terminals.removeAll { $0 === t }
        t.removeFromSuperview()
        if let area = terminalArea { equalize(area) }
        if let next = terminals.first { window?.makeFirstResponder(next) }
    }
    /// Even shares for the panes of a split.
    private func equalize(_ sv: NSSplitView) {
        let n = sv.arrangedSubviews.count
        guard n > 1 else { return }
        sv.layoutSubtreeIfNeeded()
        let total = sv.isVertical ? sv.bounds.width : sv.bounds.height
        for i in 0..<(n - 1) { sv.setPosition(total * CGFloat(i + 1) / CGFloat(n), ofDividerAt: i) }
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
        tunnel?.stop(); tunnel = nil; stopForwards()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let keyMonitorT { NSEvent.removeMonitor(keyMonitorT); self.keyMonitorT = nil }
        RemoteWindowController.open.removeAll { $0 === self }
        RemoteSession.noteOpenWindows()             // closed on purpose: not brought back next time (unless quitting)
    }

    // ---- toolbar ----
    private enum Item: String, CaseIterable { case fit, zoomOut, zoomIn, pixels, keyboard, grab, mylinux, flexibleSpace0 }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [Item] = profile.kind == .vnc ? [.fit, .zoomOut, .zoomIn, .pixels, .keyboard, .grab] : [.keyboard]
        // the launcher's own machines get the myLinux menu in the middle of the title bar
        if profile.launcherMachine { items = [.flexibleSpace0] + [.mylinux] + [.flexibleSpace0] + items }
        return items.map { $0 == .flexibleSpace0 ? .flexibleSpace : NSToolbarItem.Identifier($0.rawValue) } + [.flexibleSpace]
    }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let kind = Item(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id); item.target = self
        switch kind {
        case .mylinux:
            // a pull-down with the product name as its face; the first item is what the menu is for
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 24), pullsDown: true)
            pop.bezelStyle = .texturedRounded
            pop.addItem(withTitle: "myLinux")
            let install = NSMenuItem(title: "Install Script…", action: #selector(installScript), keyEquivalent: ""); install.target = self
            pop.menu?.addItem(install)
            pop.menu?.addItem(.separator())
            let tab = NSMenuItem(title: "New Terminal Tab", action: #selector(newTerminal), keyEquivalent: "t"); tab.target = self; pop.menu?.addItem(tab)
            let term = NSMenuItem(title: "Split Terminal", action: #selector(splitTerminal), keyEquivalent: "\r"); term.target = self; pop.menu?.addItem(term)
            let show = NSMenuItem(title: "Show Browser", action: #selector(toggleBrowser), keyEquivalent: "\r"); show.keyEquivalentModifierMask = [.command, .shift]; show.target = self; pop.menu?.addItem(show)
            for (title, sel) in [("Open Last URL in Browser", #selector(openLastURL)),
                                 ("Screenshot Browser to Machine", #selector(screenshotBrowser)), ("Paste Screenshot Path", #selector(pasteScreenshot))] {
                let mi = NSMenuItem(title: title, action: sel, keyEquivalent: ""); mi.target = self; pop.menu?.addItem(mi)
            }
            pop.menu?.delegate = self
            item.view = pop; item.label = "myLinux"; item.visibilityPriority = .high
            return item
        case .flexibleSpace0: return nil
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

    // ---- the myLinux menu: the browser pane ----
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Show Browser")?.title = browser == nil ? "Show Browser" : "Hide Browser"
        menu.item(withTitle: "Hide Browser")?.title = browser == nil ? "Show Browser" : "Hide Browser"
        menu.item(withTitle: "Screenshot Browser to Machine")?.isEnabled = browser != nil && !profile.shareMacPath.isEmpty
        menu.item(withTitle: "Paste Screenshot Path")?.isEnabled = !profile.shareMacPath.isEmpty
    }

    /// ⌘T: another terminal to the same machine, as a tab of this window.
    @objc private func newTerminal() {
        var p = profile; p.id = UUID()
        RemoteWindowController.show(p)
    }
    /// ⌘↩, as in Omarchy: one more terminal in this tab, beside the others (or under them, once the browser is
    /// on the right), the keyboard in the new one.
    @objc private func splitTerminal() {
        guard let area = terminalArea else { return }
        let t = makeTerminal()
        if let current = ssh, let i = area.arrangedSubviews.firstIndex(where: { $0 === current }) { area.insertArrangedSubview(t, at: i + 1) }
        else { area.addArrangedSubview(t) }
        equalize(area)
        window?.makeFirstResponder(t)
    }
    /// ⇧⌘↩, as in Omarchy: the browser, with the address bar ready to type into.
    private func showBrowserAndFocus() {
        if browser == nil { toggleBrowser() }
        browser?.focusAddress()
    }

    /// The browser on the right, half the window, its traffic through a tunnel into the machine; the terminals
    /// become a stack on the left.
    @objc private func toggleBrowser() {
        if browser != nil { hideBrowser(); return }
        guard let o = outer, let area = terminalArea, let t = ssh else { return }
        let tunnel = SocksTunnel(profile: profile)
        let pane = BrowserPane(machineID: profile.id, socksPort: tunnel.port)
        pane.onTitle = { [weak self] title in self?.updateStatus(); _ = title }
        pane.localForward = { [weak self] guestPort, done in self?.forward(guestPort, done) }
        pane.frame = NSRect(x: 0, y: 0, width: o.bounds.width / 2, height: o.bounds.height)
        o.addArrangedSubview(pane)
        area.isVertical = false
        equalize(o); equalize(area)
        browser = pane; self.tunnel = tunnel
        let first = t.lastURL()
        showOverlay("Opening a tunnel into the machine…")
        tunnel.start { [weak self] ok in
            guard let self, self.browser === pane else { return }
            self.hideOverlay()
            if ok { if let first { pane.load(first) } else { pane.showStart() } }
            else { self.showOverlay("The tunnel into the machine did not come up (is it running, and is SSH reachable?). Click to dismiss.") }
        }
        window?.makeFirstResponder(t)
    }
    /// A Mac port that leads to the machine's port, opened once per port and kept while the pane is open.
    private func forward(_ guestPort: Int, _ done: @escaping (UInt16?) -> Void) {
        if let f = forwards[guestPort], f.isRunning { done(f.macPort); return }
        let f = PortForward(profile: profile, guestPort: guestPort)
        forwards[guestPort] = f
        f.whenReady { ok in done(ok ? f.macPort : nil) }
    }
    private func stopForwards() { forwards.values.forEach { $0.stop() }; forwards.removeAll() }
    private func hideBrowser() {
        guard let pane = browser, let area = terminalArea else { return }
        tunnel?.stop(); tunnel = nil; stopForwards()
        pane.removeFromSuperview()
        browser = nil
        area.isVertical = true
        equalize(area)
        window?.makeFirstResponder(ssh)
    }
    private func openInBrowser(_ url: URL) {
        if browser == nil { toggleBrowser() }
        if let tunnel, tunnel.isRunning, SocksTunnel.answers(tunnel.port) { browser?.load(url) }
        else { pendingURL = url }
    }
    private var pendingURL: URL? {
        didSet { if let u = pendingURL { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let t = self.tunnel, t.isRunning else { return }
            if SocksTunnel.answers(t.port) { self.browser?.load(u); self.pendingURL = nil } else if self.pendingURL != nil { self.pendingURL = u }
        } } }
    }
    @objc private func openLastURL() {
        guard let url = ssh?.lastURL() else { showOverlay("No web address in the terminal yet. Click to dismiss."); return }
        openInBrowser(url)
    }

    /// A PNG into the machine's share folder, and its path inside the machine typed into the terminal.
    private func saveIntoShare(_ image: NSImage, prefix: String) {
        guard !profile.shareMacPath.isEmpty, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { showOverlay("This machine has no share folder. Click to dismiss."); return }
        let folder = URL(fileURLWithPath: profile.shareMacPath).appendingPathComponent("screenshots", isDirectory: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(prefix)-\(f.string(from: Date())).png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name))
        } catch { showOverlay("Could not save the screenshot: \(error.localizedDescription). Click to dismiss."); return }
        ssh?.type("\(profile.shareGuestPath)/screenshots/\(name) ")
        window?.makeFirstResponder(ssh)
    }
    @objc private func screenshotBrowser() {
        guard let browser else { showOverlay("Show the browser first. Click to dismiss."); return }
        browser.snapshot { [weak self] image in
            guard let image else { self?.showOverlay("Could not photograph the page. Click to dismiss."); return }
            self?.saveIntoShare(image, prefix: "browser")
        }
    }
    @objc private func pasteScreenshot() {
        guard let image = NSImage(pasteboard: .general) else { showOverlay("No picture on the Mac clipboard (Shift+Ctrl+⌘+4 copies a screenshot). Click to dismiss."); return }
        saveIntoShare(image, prefix: "clipboard")
    }

    var testHasBrowser: Bool { browser != nil }
    func testType(_ text: String) { ssh?.type(text + "\n") }
    func testSplit() { splitTerminal() }
    var testTerminalCount: Int { terminals.count }
    var testTerminalsStacked: Bool { terminalArea?.isVertical == false }
    /// For the scripted check: the pane on a given page, and a screenshot into the share.
    func testShowBrowser(_ url: URL) { openInBrowser(url) }
    func testScreenshotToMachine() { screenshotBrowser() }

    // ---- the myLinux menu: Install Script… ----
    private var sheetWindow: NSWindow?
    @objc private func installScript() {
        guard let window, sheetWindow == nil else { return }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: InstallScriptSheet(
            profile: profile,
            dismiss: { [weak self] in self?.endSheet() },
            run: { [weak self] in guard let self, let t = self.ssh else { return }; t.type(InstallScript.command); self.window?.makeFirstResponder(t) })))
        sheet.styleMask = [.titled]
        sheetWindow = sheet
        window.beginSheet(sheet) { _ in }
    }
    private func endSheet() {
        guard let window, let sheet = sheetWindow else { return }
        window.endSheet(sheet); sheetWindow = nil
    }
}
