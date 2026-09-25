import SwiftUI
import AppKit

struct ContentView: View {
    @State private var showWelcome = false
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var runs: RunManager
    @EnvironmentObject var remote: RemoteStore
    @StateObject private var images = ImageManager.shared
    @StateObject private var runtime = RuntimeManager.shared      // observed so the QEMU warning goes when a download lands
    @State private var selection: UUID?

    private var selected: Profile? { store.profiles.first { $0.id == selection } }
    private var selectedRemote: RemoteProfile? { remote.profiles.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Machines") {
                    ForEach(store.profiles) { p in
                        MachineRow(profile: p, runner: runs.runner(for: p.id)).tag(p.id)
                            .contextMenu {
                                Button("Duplicate") { selection = store.add(copying: p).id }
                                Button("Remove", role: .destructive) { remove(p) }
                                    .disabled(runs.runner(for: p.id).isActive)
                            }
                    }
                }
                // VNC desktops and SSH terminals reached natively from the Mac (docs/MAC-REMOTE-PLAN.md)
                Section("Remote") {
                    ForEach(remote.profiles) { r in
                        HStack(spacing: 8) {
                            Image(systemName: r.kind == .ssh ? "terminal" : "display").foregroundStyle(.secondary).frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title).lineLimit(1)
                                Text("\(r.host):\(r.port)" + (r.username.isEmpty ? "" : " · \(r.username)")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2).tag(r.id)
                        .contextMenu {
                            Button("Connect") { RemoteWindowController.show(r) }
                            Button("Remove", role: .destructive) { removeRemote(r) }
                        }
                    }
                    if remote.profiles.isEmpty {
                        Text("No remote machines yet").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            // in the sidebar's toolbar, not the section header: a click anywhere in a sidebar header folds the section
            .toolbar { ToolbarItem(placement: .automatic) { addMenu } }
        } detail: {
            if let p = selected {
                MachineView(profile: p, runner: runs.runner(for: p.id))
                    .id(p.id)
            } else if let r = selectedRemote {
                RemoteEditor(profile: r).id(r.id)
            } else {
                ContentUnavailableView("No machine selected", systemImage: "desktopcomputer",
                                       description: Text("Pick a machine on the left, or add one."))
            }
        }
        .onAppear {
            if selection == nil { selection = store.profiles.first?.id }
            images.refresh(settings); runtime.refresh(settings)
            runs.startWatching(store)
            // a fresh install: offer the Linux machines, once (File › Download Linux… brings it back)
            OmarchyManager.shared.refresh(settings); DebianManager.shared.refresh(settings)
            if !settings.developerMode, !images.present, !OmarchyManager.shared.present, !DebianManager.shared.present,
               !UserDefaults.standard.bool(forKey: "welcomeShown") {
                UserDefaults.standard.set(true, forKey: "welcomeShown"); showWelcome = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WelcomeSheet.showNotification)) { _ in showWelcome = true }
        // the version under the window's title, so it is plain which launcher is running
        .navigationSubtitle(AppInfo.versionText)
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet(images: images, omarchy: .shared, debian: .shared, runtime: runtime, done: { kinds in
                showWelcome = false
                // a machine of each downloaded kind that has none yet, and the first of them selected
                var first: UUID?
                for kind in kinds where !store.profiles.contains(where: { $0.kind == kind }) {
                    let p = store.add(kind: kind); if first == nil { first = p.id }
                }
                if let first { selection = first }
                else if let k = kinds.first, let p = store.profiles.first(where: { $0.kind == k }) { selection = p.id }
            })
            .environmentObject(settings)
        }
        .frame(minWidth: 860, minHeight: 720)
    }

    /// Everything that can be added, behind one + above the list: the two kinds of machine, the two kinds of remote
    /// connection, and the import of the guest viewer's saved machines.
    private var addMenu: some View {
        Menu {
            Button { selection = store.add(copying: selected?.kind == .mylinux ? selected : nil, kind: .mylinux).id } label: {
                Label("myLinux Machine", systemImage: "desktopcomputer")
            }
            Button { selection = store.add(copying: selected?.kind == .omarchy ? selected : nil, kind: .omarchy).id } label: {
                Label("Omarchy Machine", systemImage: "cube")
            }
            Button { selection = store.add(copying: selected?.kind == .debian ? selected : nil, kind: .debian).id } label: {
                Label("Debian Server", systemImage: "server.rack")
            }
            Divider()
            Button { selection = remote.add(.vnc).id } label: { Label("VNC Desktop", systemImage: "display") }
            Button { selection = remote.add(.ssh).id } label: { Label("SSH Terminal", systemImage: "terminal") }
            Divider()
            Button { importMachines() } label: { Label("Import from machines.json…", systemImage: "square.and.arrow.down") }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Add a machine or a remote connection")
        .accessibilityLabel("Add")
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if !settings.qemuAvailable { Banner(text: AppSettings.qemuMissingText, kind: .warning) }
            if settings.developerMode {
                Label("Developer: \(URL(fileURLWithPath: settings.repoPath).lastPathComponent)", systemImage: "hammer")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(settings.repoPath + " — run.sh, tools/ and out/ come from this checkout")
            }
            ImageStatusView(images: images)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    /// The guest's machines.json, picked with a panel that starts in the selected machine's share folder.
    private func importMachines() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Pick the viewer's machines.json (in the guest: ~/.config/mylinux/vnc/, copy it to the share)."
        if let share = (selected ?? store.profiles.first)?.shareDir, !share.isEmpty { panel.directoryURL = URL(fileURLWithPath: share, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try RemoteImport.load(url)
            let r = remote.merge(entries)
            let alert = NSAlert(); alert.messageText = "Imported \(entries.count) machine\(entries.count == 1 ? "" : "s")"
            alert.informativeText = "\(r.added) added, \(r.updated) updated" + (entries.contains { $0.password != nil } ? "; passwords went to the Keychain." : ".")
            alert.runModal()
            if let first = entries.first, let p = remote.find(first.profile.name, kind: first.profile.kind) { selection = p.id }
        } catch {
            let alert = NSAlert(error: error); alert.messageText = "Could not import \(url.lastPathComponent)"; alert.runModal()
        }
    }

    private func removeRemote(_ r: RemoteProfile) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(r.title)”?"
        alert.informativeText = "Its saved password is removed from the Keychain too."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if selection == r.id { selection = nil }
        remote.remove(r.id)
    }

    private func remove(_ p: Profile) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(p.name)” from the list?"
        alert.informativeText = "Its apps disk and share folder stay on disk:\n\(p.appsDisk)"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if selection == p.id { selection = store.profiles.first { $0.id != p.id }?.id }
        store.remove(p.id)
    }
}

private struct MachineRow: View {
    let profile: Profile
    @ObservedObject var runner: Runner

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch runner.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .inUseElsewhere: return .yellow
        case .failed: return .red
        case .stopped: return .secondary.opacity(0.5)
        }
    }

    private var subtitle: String {
        switch runner.state {
        case .running: return "Running"
        case .starting: return "Starting…"
        case .stopping: return "Shutting down…"
        case .inUseElsewhere: return "Running outside the app"
        case .failed: return "Failed"
        case .stopped:
            if profile.kind == .debian { return "Debian server · \(profile.memoryGB) GB · ssh port \(String(profile.sshPort))" }
            return "\(profile.memoryGB) GB · \(profile.grab == "opt" ? "Option as ⌘" : profile.grab == "full" ? "All keys" : "No key grab")"
        }
    }
}

struct ImageStatusView: View {
    @ObservedObject var images: ImageManager
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if images.busy {
                Text(images.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressView().controlSize(.small)
                Button("Cancel") { images.cancel() }.buttonStyle(.link).font(.caption)
            } else if images.present {
                Text("Image \(images.revision ?? "unknown")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !settings.developerMode {
                    Button("Check for a newer image") { images.download(settings) }.buttonStyle(.link).font(.caption)
                }
            } else if settings.developerMode {
                Banner(text: "No image in the checkout's out/. Build it with ./build.sh.", kind: .warning)
            } else {
                Banner(text: "The myLinux image is not downloaded yet.", kind: .warning)
                Button("Download myLinux") { images.download(settings) }.buttonStyle(.borderedProminent)
            }
            if let e = images.lastError { Banner(text: e, kind: .error) }
        }
        .onAppear { images.refresh(settings) }
    }
}

struct Banner: View {
    enum Kind { case warning, error, info }
    let text: String
    var kind: Kind = .info

    var body: some View {
        Label(text, systemImage: kind == .error ? "xmark.octagon" : kind == .warning ? "exclamationmark.triangle" : "info.circle")
            .font(.caption)
            .foregroundStyle(kind == .error ? Color.red : kind == .warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the app bundle says about itself.
enum AppInfo {
    /// "Version 0.3.2" from Info.plist (mac/build-app.sh takes it from the v* tag); a development build shows the
    /// commit too, "Version 0.3.2-4-gabc1234".
    static var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return v.isEmpty ? "Development build" : "Version \(v)"
    }
}
