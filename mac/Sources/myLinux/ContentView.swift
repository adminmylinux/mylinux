import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var runs: RunManager
    @EnvironmentObject var remote: RemoteStore
    @StateObject private var images = ImageManager.shared
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
            images.refresh(settings)
            runs.startWatching(store)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if Paths.qemu() == nil { Banner(text: "QEMU is missing. In Terminal: brew install qemu", kind: .warning) }
            if settings.developerMode {
                Label("Developer: \(URL(fileURLWithPath: settings.repoPath).lastPathComponent)", systemImage: "hammer")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(settings.repoPath + " — run.sh, tools/ and out/ come from this checkout")
            }
            ImageStatusView(images: images)
            Button { selection = store.add(copying: selected).id } label: {
                Label("Add machine", systemImage: "plus")
            }
            .buttonStyle(.link)
            HStack(spacing: 12) {
                Button { selection = remote.add(.vnc).id } label: { Label("Add VNC", systemImage: "display") }
                Button { selection = remote.add(.ssh).id } label: { Label("Add SSH", systemImage: "terminal") }
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
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
        case .stopped: return "\(profile.memoryGB) GB · \(profile.grab == "opt" ? "Option as ⌘" : profile.grab == "full" ? "All keys" : "No key grab")"
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
