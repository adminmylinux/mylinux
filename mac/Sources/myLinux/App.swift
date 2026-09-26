import SwiftUI
import AppKit

@main
struct MyLinuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ProfileStore.shared
    @StateObject private var runs = RunManager.shared
    @StateObject private var remote = RemoteStore.shared

    init() {
        // helper mode, before any window: run-omarchy.sh starts the launcher's own binary as the clipboard bridge
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--omarchy-clipboard" { exit(OmarchyClipboard.run(socketPath: args[2])) }
    }

    var body: some Scene {
        WindowGroup("myLinux Machines") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(runs)
                .environmentObject(remote)
        }
        .defaultSize(width: 1000, height: 820)
        // a machine's own app (MachineApp) shows its terminal only, never the launcher's window
        .defaultLaunchBehavior(MachineApp.active ? .suppressed : .automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                if !MachineApp.active { newItems }
            }
            if MachineApp.active { CommandGroup(replacing: .appSettings) {} }
        }
        Settings {
            SettingsView().environmentObject(settings)
        }
    }

    @ViewBuilder private var newItems: some View {
                Button("New myLinux Machine") { _ = store.add(kind: .mylinux) }.keyboardShortcut("n")
                Button("New Omarchy Machine") { _ = store.add(kind: .omarchy) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Debian Server") { _ = store.add(kind: .debian) }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Alpine Server") { _ = store.add(kind: .alpine) }
                Divider()
                Button("Download Linux…") { NotificationCenter.default.post(name: WelcomeSheet.showNotification, object: nil) }
                Button("Quick Connect…") { QuickConnect.shared.show() }.keyboardShortcut("k")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)                 // a closed serial socket must not end the app
        if MachineApp.active { MachineApp.run(); return }     // a machine's own app: its terminal, nothing else
        StatusMenu.shared.install()              // the menu bar item: the way out of a full keyboard grab
        ImageManager.shared.refresh()
        RuntimeManager.shared.refresh()
        RuntimeManager.shared.installBundledIfNeeded()   // a release build carries the QEMU runtime: no download
        RemoteProfile.removeStrayKnownHosts()            // host keys earlier launchers left in ~/Library/Application
        Handover.start()                                 // one launcher at a time: earlier ones hand their windows over
        MachineLink.serve()                              // the servers' own apps: their state, their requests
        MachineStats.shared.start()                      // CPU, memory and disk under each running machine
        SpaceHotkey.shared.update()                      // ⌘Space: Find and Run in the servers' windows
        let args = CommandLine.arguments
        // MYLINUX_TEST_AUTOSTART=omarchy,debian:2291,… (a scratch MYLINUX_SUPPORT_DIR only): start these machines at
        // launch, for photographs of the launcher with machines running; an optional port for a server
        if let list = ProcessInfo.processInfo.environment["MYLINUX_TEST_AUTOSTART"], ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] != nil {
            for item in list.split(separator: ",") {
                let parts = item.split(separator: ":")
                guard let kind = Profile.Kind(rawValue: String(parts[0])) else { continue }
                let store = ProfileStore.shared
                var p = store.profiles.first(where: { $0.kind == kind }) ?? store.add(kind: kind)
                if kind.isServer, parts.count > 1, let port = Int(parts[1]) { p.sshPort = port }
                if !kind.isServer { p.grab = "opt"; p.name = kind.title }
                store.update(p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { RunManager.shared.runner(for: p.id).start(p) }
            }
            // MYLINUX_TEST_TOUR=<folder>: once the machines are up (MYLINUX_TEST_TOUR_WAIT seconds, default 70), photograph
            // the Overview and each machine's page into the folder, then quit (the machines keep running)
            if let dir = ProcessInfo.processInfo.environment["MYLINUX_TEST_TOUR"] {
                let wait = Double(ProcessInfo.processInfo.environment["MYLINUX_TEST_TOUR_WAIT"] ?? "70") ?? 70
                let pages = [("overview", ContentView.overviewID)] + ProfileStore.shared.profiles.map { ($0.kind.rawValue, $0.id) }
                for (n, page) in pages.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait + Double(n) * 2.5) {
                        NSApp.activate(ignoringOtherApps: true)
                        NotificationCenter.default.post(name: ContentView.selectNotification, object: page.1)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait + Double(n) * 2.5 + 2) {
                        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "myLinux Machines" }) else { return }
                        let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        cap.arguments = ["-x", "-o", "-l", String(w.windowNumber), "\(dir)/\(page.0).png"]
                        try? cap.run(); cap.waitUntilExit(); print("photographed \(page.0)"); fflush(stdout)
                        if n == pages.count - 1 { exit(0) }
                    }
                }
            }
            // on a Retina display when there is one, for sharp photographs
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }),
                   let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "myLinux Machines" }) {
                    let v = retina.visibleFrame
                    w.setFrameOrigin(NSPoint(x: v.midX - w.frame.width / 2, y: v.midY - w.frame.height / 2))
                }
            }
        }
        // `myLinux --render-welcome <png>`: draw the welcome sheet to a file
        if let i = args.firstIndex(of: "--render-welcome"), i + 1 < args.count {
            if let ago = ProcessInfo.processInfo.environment["MYLINUX_RENDER_STARTED_AGO"].flatMap(Double.init) { WelcomeSheet.renderStartedAt = Date().addingTimeInterval(-ago) }
            let view = NSHostingView(rootView: WelcomeSheet(images: ImageManager(), omarchy: OmarchyManager(), debian: ServerImageManager(.debian), alpine: ServerImageManager(.alpine), runtime: RuntimeManager(), done: { _ in })
                .environmentObject(AppSettings.shared))
            view.frame = NSRect(origin: .zero, size: view.fittingSize); view.appearance = NSAppearance(named: .darkAqua)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        // `myLinux --render-settings <png>`: draw the Settings window's content to a file
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            // MYLINUX_SETTINGS_PAGE: which page (terminal, images, windows, storage, developer)
            if let page = ProcessInfo.processInfo.environment["MYLINUX_SETTINGS_PAGE"] { UserDefaults.standard.set(page, forKey: "settings.page") }
            let view = NSHostingView(rootView: SettingsView().environmentObject(AppSettings.shared))
            view.frame = NSRect(x: 0, y: 0, width: 760, height: 580); view.appearance = NSAppearance(named: .darkAqua)
            let w = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false); w.contentView = view; w.title = "Settings"
            if let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) { w.setFrameOrigin(NSPoint(x: retina.visibleFrame.midX - 380, y: retina.visibleFrame.midY - 300)) }
            w.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                cap.arguments = ["-x", "-o", "-l", String(w.windowNumber), args[i + 1]]
                try? cap.run(); cap.waitUntilExit()
                exit(0)
            }
            return
        }
        // `myLinux --render-install-script <png>`: draw the Install Script dialog to a file, with the checkout's
        // debian_install.sh in it (a look without a machine or the network)
        if let i = args.firstIndex(of: "--render-install-script"), i + 1 < args.count {
            var p = RemoteProfile(kind: .ssh); p.name = "Debian terminal"
            if let file = ProcessInfo.processInfo.environment["MYLINUX_INSTALL_SCRIPT"] { p.installScript = file; p.name = "Alpine terminal" }
            let tab: InstallScriptSheet.Tab = ProcessInfo.processInfo.environment["MYLINUX_INSTALL_TAB"] == "cloud" ? .cloud : .install
            let view = NSHostingView(rootView: InstallScriptSheet(profile: p, dismiss: {}, run: { _ in }, preset: InstallScript.bundled(p.installScriptFile) ?? "#!/bin/bash\n", tab: tab))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.appearance = NSAppearance(named: .darkAqua)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        // `myLinux --terminal-window <png>` (with MYLINUX_LOCAL_SHELL=1): open a machine terminal window on a local shell
        // and photograph it, to check the window's layout
        if let i = args.firstIndex(of: "--terminal-window"), i + 1 < args.count {
            var p = RemoteProfile(kind: .ssh); p.name = ProcessInfo.processInfo.environment["MYLINUX_TEST_NAME"] ?? "Debian terminal"; p.host = "127.0.0.1"; p.launcherMachine = true
            // MYLINUX_TEST_SSH="port|key|known_hosts|share": a real machine, and the browser pane opens on a page inside it
            var wait = 2.0
            if let spec = ProcessInfo.processInfo.environment["MYLINUX_TEST_SSH"]?.split(separator: "|").map(String.init), spec.count == 4 {
                p.port = Int(spec[0]) ?? 22; p.username = ProcessInfo.processInfo.environment["MYLINUX_TEST_USER"] ?? "debian"; p.keyFile = spec[1]
                p.sshOptions = [RemoteProfile.knownHostsOption(spec[2]), "ConnectTimeout=10"]; p.shareMacPath = spec[3]; p.shareGuestPath = "~/Mac"
                wait = 12
            }
            let c = RemoteWindowController.show(p)
            // photographs are taken on a Retina display when there is one
            if let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }), let w = c.window {
                let v = retina.visibleFrame
                w.setFrameOrigin(NSPoint(x: v.midX - w.frame.width / 2, y: v.midY - w.frame.height / 2))
            }
            // MYLINUX_TEST_KEYS=1: press ⌘↩ and ⇧⌘↩ the way the keyboard would, and report what they did
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "1" {
                func press(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) {
                    guard let w = c.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                    NSApp.postEvent(e, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { press("\r", 36, [.command]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { print("terminals after cmd-return:", c.testTerminalCount, "stacked:", c.testTerminalsStacked); press("\r", 36, [.command, .shift]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { print("browser after shift-cmd-return:", c.testHasBrowser, "stacked:", c.testTerminalsStacked); press("\r", 36, [.command]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { print("terminals after another cmd-return:", c.testTerminalCount); press("t", 17, [.command]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { print("windows after cmd-t:", RemoteWindowController.open.count); c.window?.makeKeyAndOrderFront(nil) }
                // ⌘W: the browser when it has the keyboard, then one terminal of several; ⇧⌘P: Install Script…
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { c.testFocusBrowser(); press("w", 13, [.command]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.8) { print("browser after cmd-w in it:", c.testHasBrowser, "terminals:", c.testTerminalCount); press("w", 13, [.command]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.6) { print("terminals after cmd-w:", c.testTerminalCount, "window open:", c.window?.isVisible == true); press("P", 35, [.command, .shift]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.6) { print("install script sheet after shift-cmd-p:", c.testSheetOpen) }
                wait = 9.5
            }
            // MYLINUX_TEST_KEYS=io: real key presses into the terminal, the scrollback read back, exit, reconnect
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "io" {
                func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
                    guard let w = c.window else { return }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
                    }
                }
                // US key codes for "echo https://example.org/typed" and Return
                let codes: [Character: UInt16] = ["e": 14, "c": 8, "h": 4, "o": 31, " ": 49, "t": 17, "p": 35, "s": 1, ":": 41, "/": 44, "x": 7, "a": 0, "m": 46, "l": 37, ".": 47, "r": 15, "g": 5, "y": 16, "d": 2]
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    for ch in "echo https://example.org/typed" { key(String(ch), codes[ch] ?? 0, ch == ":" ? [.shift] : []) }
                    key("\r", 36)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { print("last URL after typing:", c.testLastURL()?.absoluteString ?? "none"); c.testType("exit\n") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { print("overlay after exit:", c.testOverlayVisible, "terminals:", c.testTerminalCount); c.testReconnect() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { print("after reconnect: overlay", c.testOverlayVisible, "terminals:", c.testTerminalCount); c.testType("echo https://example.org/after-reconnect\n") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) { print("last URL after reconnect:", c.testLastURL()?.absoluteString ?? "none") }
                wait = 12
            }
            // MYLINUX_TEST_KEYS=palette: ⌥Space as the keyboard sends it, a search, Return in the palette, and what the
            // terminal ran (MYLINUX_TEST_QUERY, default "top"; the palette photographed as <png>-palette.png)
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "palette" {
                let query = ProcessInfo.processInfo.environment["MYLINUX_TEST_QUERY"] ?? "top"
                func key(_ w: NSWindow?, _ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
                    guard let w else { return }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.activate(ignoringOtherApps: true); c.window?.makeKeyAndOrderFront(nil); key(c.window, " ", 49, [.option]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    print("palette open after option-space:", c.window?.attachedSheet != nil, "programs read:", c.testPaletteLoaded)
                    print("at first:", (c.testPalette("") ?? []).prefix(8).map(\.title).joined(separator: ", "))
                    print("for \"\(query)\":", (c.testPalette(query) ?? []).prefix(6).map { "\($0.title) [\($0.command)]" }.joined(separator: ", "))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    if let sheet = c.window?.attachedSheet {
                        let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        cap.arguments = ["-x", "-o", "-l", String(sheet.windowNumber), args[i + 1].replacingOccurrences(of: ".png", with: "-palette.png")]
                        try? cap.run(); cap.waitUntilExit()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { key(c.window?.attachedSheet, "\r", 36) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                    let text = c.testScreenText() ?? ""
                    print("palette closed:", c.window?.attachedSheet == nil, "terminal shows the command's output:", text.contains("Mem:") || text.contains("PID"))
                }
                wait = 13
            }
            // MYLINUX_GHOSTTY_CONFIG=1: what Ghostty was given, and any issue it reported
            if ProcessInfo.processInfo.environment["MYLINUX_GHOSTTY_CONFIG"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("ghostty config:\n" + GhosttySshTerminal.controller.renderedConfig)
                    print("ghostty issue:", GhosttySshTerminal.controller.lastConfigurationIssue ?? "none")
                }
            }
            // MYLINUX_TEST_KEYS=copy: ⌘A then ⌘C in the terminal, and what the pasteboard holds after
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "copy" {
                // a test run is never the active app, so AppKit would not route ⌘-keys: hand them to the window's
                // key-equivalent pass directly, which is what AppKit does for the key window
                func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) {
                    guard let w = c.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                    print("key \(chars) with ⌘ handled by the window:", w.performKeyEquivalent(with: e))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    print("window key:", c.window?.isKeyWindow ?? false, "app active:", NSApp.isActive, "responder:", c.window?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")
                    NSApp.activate(ignoringOtherApps: true); c.window?.makeKeyAndOrderFront(nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                    print("then key:", c.window?.isKeyWindow ?? false, "app active:", NSApp.isActive)
                    NSPasteboard.general.clearContents(); key("a", 0, [.command])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    print("after cmd-a: selection", c.testGhostty?.testHasSelection ?? false)
                    key("c", 8, [.command])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                    let s = NSPasteboard.general.string(forType: .string) ?? ""
                    print("copied:", s.contains("first column check") ? "yes" : "no", "(\(s.count) characters)")
                }
                wait = 4
            }
            // MYLINUX_TEST_KEYS=font: ⌘= ⌘- ⌘0 through the window's key-equivalent pass, and the columns after each
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "font" {
                func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) -> Bool {
                    guard let w = c.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return false }
                    return w.performKeyEquivalent(with: e)
                }
                let steps: [(String, String, UInt16, NSEvent.ModifierFlags)] = [("cmd =", "=", 24, [.command]), ("cmd =", "=", 24, [.command]), ("cmd -", "-", 27, [.command]), ("cmd -", "-", 27, [.command]), ("cmd -", "-", 27, [.command]), ("cmd 0", "0", 29, [.command]), ("nordic cmd - (the key left of right shift)", "-", 44, [.command]), ("nordic cmd - again", "-", 44, [.command])]
                for (n, step) in steps.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(n) * 0.6) {
                        let before = c.testGhostty?.testColumns ?? 0
                        let handled = key(step.1, step.2, step.3)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { print("\(step.0): handled \(handled), columns \(before) -> \(c.testGhostty?.testColumns ?? 0)") }
                    }
                }
                wait = 8
            }
            // MYLINUX_TEST_KEYS=commands: pick "Disk space" from the Commands menu, then look for df's header on screen
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "commands" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let bar = c.testCommandBar, let df = bar.testCommands.first(where: { $0.title == "Disk space" }) else { print("no command bar"); return }
                    print("commands offered:", bar.testCommands.count); bar.onPick?(df)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    let screen = c.testGhostty?.screenText() ?? ""
                    print("df ran:", screen.contains("Filesystem") ? "yes" : "no")
                }
                wait = 6
            }
            // MYLINUX_TEST_KEYS=link: a URL on the first line, then hover and ⌘-click on it, as a person would
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "link" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { c.testType("clear; echo https://example.org/clicked\n") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    guard let w = c.window, let tl = c.testFirstTerminalTopLeft else { return }
                    // the 5th character of the first row: 6 pt padding, about 8 pt per cell, 17 pt per row
                    let p = NSPoint(x: tl.x + 6 + 8 * 5 + 4, y: tl.y - 4 - 8)
                    for (type, mods) in [(NSEvent.EventType.mouseMoved, NSEvent.ModifierFlags.command), (.leftMouseDown, .command), (.leftMouseUp, .command)] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(e, atStart: false) }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { print("link the window was asked to open:", c.testOpenedLink?.absoluteString ?? "none", "browser:", c.testHasBrowser) }
                wait = 7
            }
            // MYLINUX_TEST_KEYS=reconnect: the browser, a reconnect (as after a restart), then ⇧⌘↩ again
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_KEYS"] == "reconnect" {
                func press(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) {
                    guard let w = c.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                                                       context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                    NSApp.postEvent(e, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { press("\r", 36, [.command, .shift]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { print("browser before the reconnect:", c.testBrowserVisible); c.testReconnect() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { print("browser after the reconnect (it comes back):", c.testBrowserVisible); press("w", 13, [.command]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { c.testFocusBrowser() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { press("w", 13, [.command]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { print("browser after cmd-w:", c.testBrowserVisible); press("\r", 36, [.command, .shift]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { print("browser after shift-cmd-return:", c.testBrowserVisible) }
                wait = 8.5
            }
            // MYLINUX_TEST_SCENE="first command|second command": a product shot: the first command in the terminal, a
            // split with the second, the browser on MYLINUX_TEST_URL
            if let scene = ProcessInfo.processInfo.environment["MYLINUX_TEST_SCENE"]?.split(separator: "|").map(String.init), wait > 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { c.testType(scene.first ?? "") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { c.testSplit() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { c.testType(scene.count > 1 ? scene[1] : "") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) { c.testShowBrowser(URL(string: ProcessInfo.processInfo.environment["MYLINUX_TEST_URL"] ?? "http://localhost:3000/")!) }
                wait = 20
            } else if wait > 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { c.testShowBrowser(URL(string: ProcessInfo.processInfo.environment["MYLINUX_TEST_URL"] ?? "http://localhost:8000/")!) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { c.testScreenshotToMachine() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let n = c.window?.windowNumber ?? 0
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", "-l", String(n), args[i + 1]]
                try? t.run(); t.waitUntilExit(); exit(0)
            }
            return
        }
        // `myLinux --show-machine <kind> <png>` (MYLINUX_SUPPORT_DIR a scratch folder, MYLINUX_TEST_SELECT the kind):
        // add a machine of that kind as the + menu does and photograph the launcher's window on its page
        if let i = args.firstIndex(of: "--show-machine"), i + 2 < args.count, let kind = Profile.Kind(rawValue: args[i + 1]),
           ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] != nil {
            if !ProfileStore.shared.profiles.contains(where: { $0.kind == kind }) { _ = ProfileStore.shared.add(kind: kind) }
            func shoot(_ path: String) {
                if let main = NSApp.windows.first(where: { !($0.windowController is RemoteWindowController) && $0.isVisible && $0.title != "" }) {
                    let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); cap.arguments = ["-x", "-l", String(main.windowNumber), path]
                    try? cap.run(); cap.waitUntilExit()
                }
            }
            // MYLINUX_TEST_DOWNLOAD=1 (a server): the header's Download, photographed while it runs (<png>-busy.png)
            // and once Start is back (<png>)
            if ProcessInfo.processInfo.environment["MYLINUX_TEST_DOWNLOAD"] == "1", kind.isServer {
                let m = ServerImageManager.shared(kind), t0 = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("download pressed"); m.download(AppSettings.shared) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { shoot(args[i + 2].replacingOccurrences(of: ".png", with: "-busy.png")); print("photographed while downloading: \(m.progress)") }
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { tm in
                    if !m.busy && m.present && Date().timeIntervalSince(t0) > 7 {
                        tm.invalidate(); print("downloaded in \(Int(Date().timeIntervalSince(t0)) - 2) s")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { shoot(args[i + 2]); exit(0) }
                    } else if let e = m.lastError, !m.busy { print("download failed: \(e)"); exit(1) }
                    else if Date().timeIntervalSince(t0) > 600 { print("gave up"); exit(2) }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { shoot(args[i + 2]); exit(0) }
            return
        }
        // `myLinux --hold-terminal <kind>` (MYLINUX_SUPPORT_DIR, MYLINUX_HANDOVER_TEST=1): an earlier launcher for the
        // handover test: pick up the running machine of that kind, open its terminal, and keep running
        if let i = args.firstIndex(of: "--hold-terminal"), i + 1 < args.count, let kind = Profile.Kind(rawValue: args[i + 1]),
           let p = ProfileStore.shared.profiles.first(where: { $0.kind == kind }) {
            let runner = RunManager.shared.runner(for: p.id)
            RunManager.shared.startWatching(ProfileStore.shared)
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                if runner.state == .inUseElsewhere { t.invalidate(); runner.openTerminal(p); print("holding the terminal of \(p.name), pid \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout) }
            }
            return
        }
        // `myLinux --handover-check <kind> <png>` (MYLINUX_SUPPORT_DIR, MYLINUX_HANDOVER_TEST=1): the newer launcher:
        // after the handover, report whether the machine's terminal came back here, and photograph it
        if let i = args.firstIndex(of: "--handover-check"), i + 2 < args.count, let kind = Profile.Kind(rawValue: args[i + 1]),
           let p = ProfileStore.shared.profiles.first(where: { $0.kind == kind }) {
            RunManager.shared.startWatching(ProfileStore.shared)
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                let c = RemoteWindowController.open.first { ($0.profile.machineID ?? $0.profile.id) == p.id }
                print("terminal reopened here:", c != nil, "state:", RunManager.shared.runner(for: p.id).state)
                if let n = c?.window?.windowNumber {
                    let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); cap.arguments = ["-x", "-l", String(n), args[i + 2]]
                    try? cap.run(); cap.waitUntilExit()
                }
                exit(0)
            }
            return
        }
        // `myLinux --adopt-machine <kind> <png>` (MYLINUX_SUPPORT_DIR a scratch folder): a machine of that kind that an
        // earlier launcher started and left running: wait for "started by an earlier launcher", photograph the
        // launcher's window, open the terminal as the Terminal button does, then shut it down from here
        if let i = args.firstIndex(of: "--adopt-machine"), i + 2 < args.count, let kind = Profile.Kind(rawValue: args[i + 1]),
           ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] != nil, let p = ProfileStore.shared.profiles.first(where: { $0.kind == kind }) {
            let runner = RunManager.shared.runner(for: p.id)
            RunManager.shared.startWatching(ProfileStore.shared)
            let t0 = Date()
            func say(_ m: String) { print(String(format: "%6.1fs ", Date().timeIntervalSince(t0)) + m); fflush(stdout) }
            var phase = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                switch phase {
                case 0 where runner.state == .inUseElsewhere:
                    phase = 1; say("state: running outside this launcher")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if let main = NSApp.windows.first(where: { !($0.windowController is RemoteWindowController) && $0.isVisible && $0.title != "" }) {
                            let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); cap.arguments = ["-x", "-l", String(main.windowNumber), args[i + 2]]
                            try? cap.run(); cap.waitUntilExit(); say("photographed the launcher window")
                        }
                        say("Terminal pressed"); runner.openTerminal(p); phase = 2
                    }
                case 2 where RemoteWindowController.open.contains(where: { $0.profile.id == p.id }):
                    phase = 3; say("terminal window opened (ssh ready: \(runner.sshReady))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { say("Shut Down pressed"); runner.stop(); phase = 4 }
                case 4 where runner.state == .stopped:
                    timer.invalidate(); say("stopped"); exit(0)
                default:
                    if Date().timeIntervalSince(t0) > 120 { say("gave up in phase \(phase), state \(runner.state)"); exit(2) }
                }
            }
            return
        }
        // `myLinux --start-machine <kind> <png>` (MYLINUX_SUPPORT_DIR must name a scratch folder): the product path end to
        // end: add a machine of that kind as the + menu does (MYLINUX_TEST_PORT overrides a server's SSH port), start it as
        // the Start button does, log each state and when its terminal window opens, and photograph that window 15 s later
        if let i = args.firstIndex(of: "--start-machine"), i + 2 < args.count, let kind = Profile.Kind(rawValue: args[i + 1]) {
            let env = ProcessInfo.processInfo.environment
            guard env["MYLINUX_SUPPORT_DIR"] != nil else { print("--start-machine needs MYLINUX_SUPPORT_DIR (a scratch folder)"); exit(64) }
            let store = ProfileStore.shared
            var p = store.profiles.first(where: { $0.kind == kind }) ?? store.add(kind: kind)
            if let port = env["MYLINUX_TEST_PORT"].flatMap(Int.init) { p.sshPort = port; store.update(p) }
            if let cloud = env["MYLINUX_TEST_CLOUD"] { p.cloudFolders = cloud.split(separator: ",").map(String.init); store.update(p) }
            let runner = RunManager.shared.runner(for: p.id)
            let t0 = Date()
            func say(_ m: String) { print(String(format: "%6.1fs ", Date().timeIntervalSince(t0)) + m); fflush(stdout) }
            say("starting \(p.name) (\(kind.rawValue)), ssh port \(p.sshPort), log \(runner.logFile.path)")
            runner.start(p)
            // MYLINUX_TEST_EARLY_TERMINAL=1: press Terminal 2 s after Start, long before sshd answers
            if env["MYLINUX_TEST_EARLY_TERMINAL"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { say("Terminal pressed"); runner.openTerminal(p) } }
            // MYLINUX_TEST_STALE_WINDOW=1: a terminal window already open at Start (it fails, as in a left-over window)
            if env["MYLINUX_TEST_STALE_WINDOW"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { say("stale window opened"); RemoteWindowController.show(p.terminalProfile) } }
            var last = ""
            var windowAt: Date?
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                let st = "\(runner.state)"
                if st != last { say("state: \(st)"); last = st }
                // MYLINUX_TEST_BOOT_SHOT=<png>: the launcher's own window 8 s into the start (the count on the machine page)
                if let shot = env["MYLINUX_TEST_BOOT_SHOT"], windowAt == nil, Date().timeIntervalSince(t0) > 8, !FileManager.default.fileExists(atPath: shot),
                   let main = NSApp.windows.first(where: { !($0.windowController is RemoteWindowController) && $0.isVisible && $0.title != "" }) {
                    let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); cap.arguments = ["-x", "-l", String(main.windowNumber), shot]
                    try? cap.run(); cap.waitUntilExit(); say("photographed the launcher window")
                }
                // MYLINUX_TEST_MACHINE_APP=1: the terminal opens in the machine's own app; name it, and photograph its
                // window (after the app's own cloud restart when MYLINUX_TEST_RESTART_CLOUD is set)
                if env["MYLINUX_TEST_MACHINE_APP"] == "1" {
                    if windowAt == nil, runner.sshReady, let app = MachineApp.running(p) {
                        windowAt = Date()
                        say("machine app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) pid \(app.processIdentifier) at \(app.bundleURL?.path ?? "?")")
                        let restart = env["MYLINUX_TEST_RESTART_CLOUD"] != nil
                        func shoot(_ path: String) {
                            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                            let wins = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
                            guard let n = wins.first?[kCGWindowNumber as String] as? Int else { say("no window of the machine app on screen"); return }
                            let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); cap.arguments = ["-x", "-o", "-l", String(n), path]
                            try? cap.run(); cap.waitUntilExit(); say("photographed the machine app's window (\(wins.count) window(s))")
                        }
                        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { tm in
                            if restart {
                                if runner.restartBeganAt != nil, windowAt.map({ Date().timeIntervalSince($0) > 9 }) == true, !FileManager.default.fileExists(atPath: args[i + 2].replacingOccurrences(of: ".png", with: "-mid.png")) {
                                    shoot(args[i + 2].replacingOccurrences(of: ".png", with: "-mid.png"))
                                }
                                guard let began = runner.restartBeganAt, let ready = runner.readyAt, ready > began else { return }
                                tm.invalidate(); say("ready again \(Runner.seconds(ready.timeIntervalSince(began))) after the restart began")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { shoot(args[i + 2]); say("qmp \(runner.qmpSocket)"); exit(0) }
                            } else if Date().timeIntervalSince(windowAt ?? Date()) > 8 {
                                tm.invalidate(); shoot(args[i + 2]); say("qmp \(runner.qmpSocket)"); exit(0)
                            }
                        }
                    }
                } else if windowAt == nil, runner.sshReady || env["MYLINUX_TEST_STALE_WINDOW"] != "1",
                   let c = RemoteWindowController.open.first(where: { $0.profile.id == p.id }) {
                    // MYLINUX_TEST_RESTART_CLOUD=dropbox: then save cloud folders as the Cloud tab does, and photograph
                    // the restart's progress halfway (<png>-mid.png) and when ready (<png>)
                    if let cloud = env["MYLINUX_TEST_RESTART_CLOUD"] {
                        windowAt = Date(); say("terminal window opened; restarting for \(cloud)")
                        var q = store.profiles.first { $0.id == p.id } ?? p
                        q.cloudFolders = cloud.split(separator: ",").map(String.init); store.update(q)
                        runner.restart(q); c.testShowRestartProgress()
                        func shootSheet(_ path: String) {
                            let n = c.window?.attachedSheet?.windowNumber ?? c.window?.windowNumber ?? 0
                            let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); cap.arguments = ["-x", "-l", String(n), path]
                            try? cap.run(); cap.waitUntilExit()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { shootSheet(args[i + 2].replacingOccurrences(of: ".png", with: "-mid.png")); say("photographed the restart halfway") }
                        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { tm in
                            guard let began = runner.restartBeganAt, let ready = runner.readyAt, ready > began else { return }
                            tm.invalidate(); say("ready again \(Runner.seconds(ready.timeIntervalSince(began))) after the restart began")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { shootSheet(args[i + 2]); say("photographed; qmp \(runner.qmpSocket)"); exit(0) }
                        }
                        return
                    }
                    windowAt = Date(); say("terminal window opened")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        let n = c.window?.windowNumber ?? 0
                        let cap = Process(); cap.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); cap.arguments = ["-x", "-l", String(n), args[i + 2]]
                        try? cap.run(); cap.waitUntilExit(); say("photographed; qmp \(runner.qmpSocket)"); exit(0)
                    }
                }
                if case .failed = runner.state { timer.invalidate(); say("failed; last log lines:\n" + ((try? String(contentsOf: runner.logFile, encoding: .utf8)) ?? "").suffix(1500)); exit(1) }
                if Date().timeIntervalSince(t0) > 300 { say("gave up after 300 s"); exit(2) }
            }
            return
        }
        // `myLinux --render-terminal <png>`: draw a local terminal running a short command, to check the text placement
        if let i = args.firstIndex(of: "--render-terminal"), i + 1 < args.count {
            var p = RemoteProfile(kind: .ssh); p.name = "render"
            let width = Double(ProcessInfo.processInfo.environment["RENDER_WIDTH"] ?? "600") ?? 600
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            let t = SshTerminal(profile: p); t.frame = w.contentView!.bounds; w.contentView!.addSubview(t)
            t.startProcess(executable: "/bin/sh", args: ["-c", "printf 'Xabcdefghij first column check\\n0123456789 second line\\n'"], environment: nil, currentDirectory: nil)
            w.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let rep = t.bitmapImageRepForCachingDisplay(in: t.bounds) {
                    t.cacheDisplay(in: t.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                exit(0)
            }
            return
        }
        // `myLinux --remote <profile id>`: open a remote machine (tests drive the bare binary this way)
        if let i = args.firstIndex(of: "--remote"), i + 1 < args.count, let id = UUID(uuidString: args[i + 1]),
           let p = RemoteStore.shared.profiles.first(where: { $0.id == id }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { RemoteWindowController.show(p) }
        } else {
            // the remote windows open when the launcher last quit or died come back (closed on purpose: none)
            let again = RemoteSession.restore()
            if !again.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { again.forEach { RemoteWindowController.show($0) } } }
        }
    }

    /// mylinux-launcher://start — sent by the myLinux app in the Dock (tools/make-app-bundle.sh) when it is clicked:
    /// bring the machine forward if it runs, otherwise start the machine used last (the first one before any start).
    /// mylinux://vnc/<name>, mylinux://ssh/<name>, mylinux://remote/<name or id> open a remote machine (RemoteLink).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch RemoteLink.parse(url) {
            case .start: QuickStart.run()
            case .startMachine(let id):
                if let p = ProfileStore.shared.profiles.first(where: { $0.id == id }) { QuickStart.start(p) } else { NSApp.activate() }
            case .remote(let kind, let name):
                if let p = RemoteStore.shared.find(name, kind: kind) { RemoteWindowController.show(p) }
                else { NSApp.activate(ignoringOtherApps: true); NSLog("no remote machine named %@ for %@", name, url.absoluteString) }
            case nil: break
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) { RemoteSession.quitting = true }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        MachineApp.active || RunManager.shared.active.isEmpty
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard MachineApp.active else { return true }
        MachineApp.reopen(); return false
    }

    /// Machines keep running when the launcher quits (they are their own QEMU processes), so say so and offer to
    /// shut them down first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MachineApp.active { return .terminateNow }       // the machine keeps running: it is the launcher's
        RemoteSession.quitting = true            // remote windows closing from here on are not closed on purpose
        if Handover.handingOver { return .terminateNow }      // a newer launcher takes over; the machines keep running
        let running = RunManager.shared.active
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "A myLinux machine is still running." : "\(running.count) myLinux machines are still running."
        alert.informativeText = "Quitting the launcher leaves them running; you can shut them down from their own windows.\n\nShutting down here powers the guests off cleanly first."
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Leave Running")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            running.forEach { $0.stop() }
            waitForShutdown(deadline: Date().addingTimeInterval(45))
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            RemoteSession.quitting = false
            return .terminateCancel
        }
    }

    private func waitForShutdown(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if RunManager.shared.active.isEmpty || Date() >= deadline {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                self?.waitForShutdown(deadline: deadline)
            }
        }
    }
}

enum QuickStart {
    static let lastKey = "lastStartedProfile"

    static func run(store: ProfileStore = .shared, runs: RunManager = .shared) {
        let last = UserDefaults.standard.string(forKey: lastKey).flatMap(UUID.init(uuidString:))
        guard let profile = store.profiles.first(where: { $0.id == last }) ?? store.profiles.first else {
            NSApp.activate(); return
        }
        start(profile, runs: runs)
    }

    /// Starts a machine, or brings its window forward when it already runs (the Dock icon and ⌘K).
    static func start(_ profile: Profile, runs: RunManager = .shared) {
        let runner = runs.runner(for: profile.id)
        if runner.isActive || Runner.diskInUse(profile.appsDisk) {
            // already running: a server's terminal comes forward (its own app), a desktop's own app comes forward
            if profile.isServer { runner.openTerminal(profile); return }
            MachineApp.running(profile)?.activate()
            return
        }
        runner.start(profile)
        if case .failed = runner.state { NSApp.activate() }       // show the reason in the launcher
    }
}

