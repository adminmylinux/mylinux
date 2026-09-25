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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New myLinux Machine") { _ = store.add(kind: .mylinux) }.keyboardShortcut("n")
                Button("New Omarchy Machine") { _ = store.add(kind: .omarchy) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Debian Server") { _ = store.add(kind: .debian) }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Alpine Server") { _ = store.add(kind: .alpine) }
                Divider()
                Button("Download Linux…") { NotificationCenter.default.post(name: WelcomeSheet.showNotification, object: nil) }
                Button("Quick Connect…") { QuickConnect.shared.show() }.keyboardShortcut("k")
            }
        }
        Settings {
            SettingsView().environmentObject(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)                 // a closed serial socket must not end the app
        StatusMenu.shared.install()              // the menu bar item: the way out of a full keyboard grab
        ImageManager.shared.refresh()
        RuntimeManager.shared.refresh()
        RuntimeManager.shared.installBundledIfNeeded()   // a release build carries the QEMU runtime: no download
        RemoteProfile.removeStrayKnownHosts()            // host keys earlier launchers left in ~/Library/Application
        let args = CommandLine.arguments
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
                if windowAt == nil, runner.sshReady || env["MYLINUX_TEST_STALE_WINDOW"] != "1",
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
            case .remote(let kind, let name):
                if let p = RemoteStore.shared.find(name, kind: kind) { RemoteWindowController.show(p) }
                else { NSApp.activate(ignoringOtherApps: true); NSLog("no remote machine named %@ for %@", name, url.absoluteString) }
            case nil: break
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) { RemoteSession.quitting = true }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        RunManager.shared.active.isEmpty
    }

    /// Machines keep running when the launcher quits (they are their own QEMU processes), so say so and offer to
    /// shut them down first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RemoteSession.quitting = true            // remote windows closing from here on are not closed on purpose
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
            // already running: its window is a "myLinux" app instance; bring one forward
            NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mylinux.vm").first?.activate()
            return
        }
        runner.start(profile)
        if case .failed = runner.state { NSApp.activate() }       // show the reason in the launcher
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var confirmClear = false
    @State private var clearError: String?
    @StateObject private var images = ImageManager.shared
    @StateObject private var runtime = RuntimeManager.shared

    var body: some View {
        Form {
            Section("myLinux image") {
                LabeledContent("Source") {
                    Text(settings.developerMode ? "The checkout's out/ folder" : "Downloaded releases")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Folder") { Text(settings.outDir.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary) }
                LabeledContent("Version") { Text(images.revision ?? "none yet").foregroundStyle(.secondary) }
                if !settings.developerMode {
                    Button(images.present ? "Download the latest release" : "Download myLinux") { images.download(settings) }
                        .disabled(images.busy)
                }
            }
            Section("QEMU") {
                LabeledContent("In use") {
                    Text(runtime.present ? "Accelerated runtime \((runtime.revision ?? "").replacingOccurrences(of: "qemu-runtime-", with: ""))" : (Paths.qemu() ?? "none — download below, or brew install qemu"))
                        .foregroundStyle(settings.qemuAvailable ? Color.secondary : Color.orange)
                        .lineLimit(1).truncationMode(.head)
                }
                if runtime.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(runtime.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Cancel") { runtime.cancel() }
                    }
                } else {
                    HStack {
                        Button(runtime.present ? "Check for a newer runtime" : "Download the accelerated QEMU") { runtime.download(settings) }
                        if runtime.present { Button("Remove") { runtime.remove(settings) } }
                    }
                }
                if let e = runtime.lastError { Banner(text: e, kind: .error) }
                Text(RuntimeManager.bundledTarball != nil
                     ? "myLinux's own QEMU with GPU support (VirGL, drawn through Metal) came with the app and is installed on its first start; the button fetches a newer one if there is one. Its sources and licences are in the runtime's NOTICES.md."
                     : "myLinux's own QEMU with GPU support (VirGL, drawn through Metal): about 10 MB to download, no Homebrew needed. Machines use it from their next start; without it they start with Homebrew's QEMU. Its sources and licences are in the runtime's NOTICES.md.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Developer") {
                LabeledContent("myLinux checkout") {
                    HStack {
                        Text(settings.repoPath.isEmpty ? "none" : settings.repoPath)
                            .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseRepo)
                        Button("Clear") { settings.repoPath = "" }.disabled(settings.repoPath.isEmpty)
                    }
                }
                Text("With a checkout, machines start from its run.sh, tools/ and out/ — so a locally built image and hot-swapped binaries in share/ are what you get. Without one, the app uses its own copy of the scripts and the downloaded release.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !settings.repoPath.isEmpty && !settings.developerMode {
                    Banner(text: "That folder has no run.sh and tools/get-image.sh, so it is ignored.", kind: .warning)
                }
            }
            Section("Window") {
                Toggle("Move the machine window onto the screen it was sized for", isOn: $settings.placeWindow)
                Text("macOS asks for permission to control System Events the first time, because moving another app's window goes through AppleScript. Without it the window opens wherever macOS puts it, which on a second display can be the wrong size.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Storage") {
                LabeledContent("Machines folder") { Text(Paths.support.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary) }
            }
            Section("Start over") {
                Button("Clear All Data on This Mac…", role: .destructive) { confirmClear = true }
                Text("Deletes every machine and its disk, the downloaded Linuxes and QEMU, the launcher's settings, saved remote passwords and the browser's data, then restarts the launcher as if it were new. A developer checkout's out/ folder is not touched.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let clearError { Banner(text: clearError, kind: .error) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .confirmationDialog("Clear all myLinux data on this Mac?", isPresented: $confirmClear) {
            Button("Delete Everything and Restart", role: .destructive) { clearError = StartOver.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every machine, its disk and everything inside it is deleted, along with the downloads and settings. This cannot be undone.")
        }
        .onAppear { images.refresh(settings); runtime.refresh(settings) }
        .onChange(of: settings.repoPath) { _, _ in images.refresh(settings); runtime.refresh(settings) }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Pick a myLinux source checkout (the folder with run.sh)."
        if panel.runModal() == .OK, let url = panel.url { settings.repoPath = url.path }
    }
}
