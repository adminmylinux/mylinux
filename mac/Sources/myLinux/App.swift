import SwiftUI
import AppKit

@main
struct MyLinuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var store = ProfileStore.shared
    @StateObject private var runs = RunManager.shared

    var body: some Scene {
        WindowGroup("myLinux Machines") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(runs)
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
        ImageManager.shared.refresh()
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
