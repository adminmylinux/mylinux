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
                Button("New Machine") { _ = store.add() }.keyboardShortcut("n")
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
        // `myLinux --remote <profile id>`: open a remote machine (tests drive the bare binary this way)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--remote"), i + 1 < args.count, let id = UUID(uuidString: args[i + 1]),
           let p = RemoteStore.shared.profiles.first(where: { $0.id == id }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { RemoteWindowController.show(p) }
        }
    }

    /// mylinux-launcher://start — sent by the myLinux app in the Dock (tools/make-app-bundle.sh) when it is clicked:
    /// bring the machine forward if it runs, otherwise start the machine used last (the first one before any start).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "mylinux-launcher" {
            if url.host == "start" { QuickStart.run() }
            // mylinux-launcher://remote/<profile id>  opens a remote machine's window
            if url.host == "remote", let id = UUID(uuidString: url.lastPathComponent), let p = RemoteStore.shared.profiles.first(where: { $0.id == id }) {
                RemoteWindowController.show(p)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        RunManager.shared.active.isEmpty
    }

    /// Machines keep running when the launcher quits (they are their own QEMU processes), so say so and offer to
    /// shut them down first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
            Section("Requirements") {
                LabeledContent("QEMU") {
                    Text(Paths.qemu() ?? "not installed — brew install qemu")
                        .foregroundStyle(Paths.qemu() == nil ? Color.orange : Color.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                LabeledContent("Machines folder") { Text(Paths.support.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 430)
        .onAppear { images.refresh(settings) }
        .onChange(of: settings.repoPath) { _, _ in images.refresh(settings) }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Pick a myLinux source checkout (the folder with run.sh)."
        if panel.runModal() == .OK, let url = panel.url { settings.repoPath = url.path }
    }
}
