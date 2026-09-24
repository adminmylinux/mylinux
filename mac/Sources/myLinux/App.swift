import SwiftUI
import AppKit

@main
struct MyLinuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ProfileStore.shared
    @StateObject private var runs = RunManager.shared
    @StateObject private var remote = RemoteStore.shared

    var body: some Scene {
        WindowGroup("myLinux Machines") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(runs)
                .environmentObject(remote)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New myLinux Machine") { _ = store.add(kind: .mylinux) }.keyboardShortcut("n")
                Button("New Omarchy Machine") { _ = store.add(kind: .omarchy) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Debian Server") { _ = store.add(kind: .debian) }.keyboardShortcut("n", modifiers: [.command, .option])
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
        let args = CommandLine.arguments
        // `myLinux --agent-script claude,codex,basics`: print the Install Agents script for that choice and quit
        // (the end-to-end check runs it over ssh against a test machine)
        if let i = args.firstIndex(of: "--agent-script") {
            let picks = i + 1 < args.count ? args[i + 1].split(separator: ",").map(String.init) : []
            var o = AgentInstallOptions(); o.claude = picks.contains("claude"); o.codex = picks.contains("codex"); o.basics = picks.contains("basics")
            print(o.script); exit(o.problems.isEmpty ? 0 : 1)
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
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
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
