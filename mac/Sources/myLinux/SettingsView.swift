import SwiftUI
import AppKit

/// The launcher's Settings: a category list on the left (Terminal, Images & runtime, Windows, Storage, Developer)
/// and one page at a time, each short, with the technical details folded under "Details".
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case terminal, images, windows, storage, developer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terminal: return "Terminal"
            case .images: return "Images & runtime"
            case .windows: return "Windows"
            case .storage: return "Storage"
            case .developer: return "Developer"
            }
        }
        var symbol: String {
            switch self {
            case .terminal: return "terminal"
            case .images: return "shippingbox"
            case .windows: return "macwindow.on.rectangle"
            case .storage: return "internaldrive"
            case .developer: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    @EnvironmentObject var settings: AppSettings
    @AppStorage("settings.page") private var pageName = Page.terminal.rawValue
    private var page: Page { Page(rawValue: pageName) ?? .terminal }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preferences").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(Page.allCases) { p in
                    Button { pageName = p.rawValue } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.symbol).frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                            Text(p.title).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(page == p ? Color.accentColor.opacity(0.22) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("myLinux Launcher \(AppInfo.shortVersion)").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            .padding(12)
            .frame(width: 190)
            .background(Color.primary.opacity(0.03))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .terminal: TerminalSettingsPage()
                    case .images: ImagesSettingsPage()
                    case .windows: WindowsSettingsPage()
                    case .storage: StorageSettingsPage()
                    case .developer: DeveloperSettingsPage()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(width: 760, height: 580)
        .environmentObject(settings)
    }
}

/// A page's heading: its title and one line under it.
private struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

/// A key as it looks on the keyboard, for the short help lines.
private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.25)))
    }
}

// ---- Terminal -------------------------------------------------------------------------------------------------------
private struct TerminalSettingsPage: View {
    @AppStorage(TerminalEngine.settingKey, store: TerminalEngine.defaults) private var engine = TerminalEngine.ghostty.rawValue
    @AppStorage(SpaceHotkey.settingKey) private var cmdSpace = true
    @State private var trusted = AXIsProcessTrusted()
    private var ghostty: Bool { engine == TerminalEngine.ghostty.rawValue }

    var body: some View {
        PageHeader(title: "Terminal", subtitle: "For Debian, Alpine and SSH connections.")
        Text("Terminal engine").font(.headline)
        HStack(spacing: 12) {
            engineCard(.ghostty, "Ghostty", "GPU accelerated")
            engineCard(.swiftTerm, "SwiftTerm", "The earlier terminal")
        }
        Text("Applies to new terminals. Open ones keep their engine.").font(.caption).foregroundStyle(.secondary)
        preview
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) { Text("Find & Run with").fontWeight(.semibold); KeyCap(text: "⌘ Space") }
                        Text("Search what is installed in Debian and Alpine, and run it.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $cmdSpace).toggleStyle(.switch).labelsHidden()
                        .onChange(of: cmdSpace) { _, _ in SpaceHotkey.shared.update() }
                }
                if cmdSpace && !trusted {
                    HStack {
                        Label("Needs the Accessibility permission; until then ⌥Space does it.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…") { KeyboardGrab.askPermission() }
                    }
                }
                DisclosureGroup("Shortcut behavior") {
                    Text("Like Super+Space in Omarchy. The launcher takes ⌘Space only while a Debian or Alpine window is in front; everywhere else Spotlight keeps it. It uses the Accessibility permission Omarchy's \"every key\" mode asks for. ⌥Space and CMD › Find and Run… do the same without it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                .font(.callout)
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }

    private func engineCard(_ e: TerminalEngine, _ title: String, _ subtitle: String) -> some View {
        let on = engine == e.rawValue
        return Button { engine = e.rawValue } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A drawn sample of each engine's look (not a live terminal).
    private var preview: some View {
        let mono = ghostty ? Font.custom("JetBrains Mono", size: 12.5).monospaced() : Font.custom("Menlo", size: 12)
        let prompt = ghostty ? Color(red: 0.55, green: 0.85, blue: 0.62) : Color(red: 0.45, green: 0.78, blue: 0.9)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("›_  debian — ~").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ghostty ? "Ghostty" : "SwiftTerm").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                (Text("debian:~ $ ").foregroundColor(prompt) + Text("uname -s"))
                Text("Linux")
                (Text("debian:~ $ ").foregroundColor(prompt) + Text("▍"))
            }
            .font(mono).foregroundStyle(Color(white: 0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(ghostty ? Color(red: 0.11, green: 0.12, blue: 0.14) : Color(white: 0.08))
            Divider()
            HStack(spacing: 8) {
                KeyCap(text: "⌘C"); Text("Copy")
                KeyCap(text: "⌘V"); Text("Paste")
                if ghostty { KeyCap(text: "⌘ + / −"); Text("Text size") }
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }
}

// ---- Images & runtime -----------------------------------------------------------------------------------------------
private struct ImagesSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var images = ImageManager.shared
    @StateObject private var omarchy = OmarchyManager.shared
    @StateObject private var debian = ServerImageManager.debian
    @StateObject private var alpine = ServerImageManager.alpine
    @StateObject private var runtime = RuntimeManager.shared

    var body: some View {
        PageHeader(title: "Images & runtime", subtitle: "What the machines are made from. Each downloads once; machines keep their own disks.")
        Text("Linux").font(.headline)
        VStack(spacing: 0) {
            row(icon: MachineIcon.image(.mylinux), name: "myLinux", size: "110 MB", loader: images,
                status: settings.developerMode ? "From the checkout's out/ folder" : (images.present ? "Installed · \(images.revision ?? "")" : nil),
                action: settings.developerMode ? nil : (images.present ? "Update" : "Download"), start: { images.download(settings) })
            Divider()
            row(icon: MachineIcon.image(.omarchy), name: "Omarchy", size: "1.4 GB", loader: omarchy,
                status: omarchy.present ? "Installed · \(omarchy.revision ?? "")" : nil,
                action: omarchy.present ? "Update" : "Download", start: { omarchy.download(settings) })
            Divider()
            row(icon: MachineIcon.image(.debian), name: "Debian", size: "300 MB", loader: debian,
                status: debian.present ? "Installed · \(debian.revision ?? "")" : nil,
                action: debian.present ? "Update" : "Download", start: { debian.download(settings) })
            Divider()
            row(icon: MachineIcon.image(.alpine), name: "Alpine", size: "100 MB", loader: alpine,
                status: alpine.present ? "Installed · \(alpine.revision ?? "")" : nil,
                action: alpine.present ? "Update" : "Download", start: { alpine.download(settings) })
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        Text("An update is used by machines made from then on; existing machines keep the disk they have.")
            .font(.caption).foregroundStyle(.secondary)

        Text("Runtime").font(.headline).padding(.top, 6)
        Card(padding: 0) {
            row(icon: nil, symbol: "cpu", name: "QEMU", size: "10 MB", loader: runtime,
                status: runtime.present ? "Accelerated runtime \((runtime.revision ?? "").replacingOccurrences(of: "qemu-runtime-", with: "")) · in use"
                                        : (Paths.qemu().map { "Homebrew's QEMU · \($0)" }),
                action: runtime.present ? "Check for update" : "Download", start: { runtime.download(settings) })
        }
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Folder") { Text(settings.outDir.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary).textSelection(.enabled) }
                Text(RuntimeManager.bundledTarball != nil
                     ? "myLinux's own QEMU with GPU support (VirGL, drawn through Metal) comes with the app and is installed when it starts; Check for update fetches a newer one. Its sources and licences are in the runtime's NOTICES.md."
                     : "myLinux's own QEMU with GPU support (VirGL, drawn through Metal), about 10 MB, no Homebrew needed. Machines use it from their next start. Its sources and licences are in the runtime's NOTICES.md.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if runtime.present, !runtime.busy { Button("Remove the runtime") { runtime.remove(settings) } }
            }
            .padding(.top, 6)
        }
        .onAppear { images.refresh(settings); omarchy.refresh(settings); debian.refresh(settings); alpine.refresh(settings); runtime.refresh(settings) }
    }

    private func row(icon: NSImage?, symbol: String = "shippingbox", name: String, size: String, loader: ScriptDownloader,
                     status: String?, action: String?, start: @escaping () -> Void) -> some View {
        DownloadRow(icon: icon, symbol: symbol, name: name, size: size, loader: loader, status: status, action: action, start: start)
    }
}

private struct DownloadRow: View {
    let icon: NSImage?
    let symbol: String
    let name: String
    let size: String
    @ObservedObject var loader: ScriptDownloader
    let status: String?
    let action: String?
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 34, height: 34) }
                else { Image(systemName: symbol).font(.title3).frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07))) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fontWeight(.semibold)
                    if loader.busy {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("\(loader.progress) · \(Runner.seconds(ctx.date.timeIntervalSince(loader.startedAt ?? ctx.date)))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                        }
                    } else if let status {
                        Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .labelStyle(StatusLabel())
                    } else {
                        Text("Not downloaded · \(size)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if loader.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { loader.cancel() }
                } else if let action {
                    Button(action, action: start)
                }
            }
            if let e = loader.lastError { Banner(text: e, kind: .error) }
        }
        .padding(12)
    }
}

/// A green check before an installed item's status.
private struct StatusLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.foregroundStyle(.green); configuration.title }
    }
}

// ---- Windows --------------------------------------------------------------------------------------------------------
private struct WindowsSettingsPage: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        PageHeader(title: "Windows", subtitle: "Where the myLinux and Omarchy windows open.")
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open the window on the screen it was sized for").fontWeight(.semibold)
                        Text("A machine's desktop is made to fit the screen under the pointer at Start; the window is moved there.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.placeWindow).toggleStyle(.switch).labelsHidden()
                }
                displays.animation(.easeInOut(duration: 0.3), value: settings.placeWindow)
            }
        }
        DisclosureGroup("Details") {
            Text("macOS asks once for permission to control System Events, because moving another app's window goes through AppleScript. Without it the window opens wherever macOS puts it, which on a second display can be the wrong size. The title bar's − and + change the size by 10% at any time, and View › Zoom To Fit makes the window resizable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }

    /// Two displays: with placement on, the window sits centred on the one it was sized for; off, it opens where
    /// macOS puts it, on the other one and too big for it.
    private var displays: some View {
        let on = settings.placeWindow
        return VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 18) {
                screen(width: 190, height: 120, label: "MacBook", target: false, window: on ? nil : CGSize(width: 176, height: 104))
                screen(width: 250, height: 145, label: "Sized for this display", target: true, window: on ? CGSize(width: 226, height: 124) : nil)
            }
            Text(on ? "The window opens on the display it was made for, at the right size."
                    : "The window opens where macOS puts it: here on the smaller screen, bigger than it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func screen(width: CGFloat, height: CGFloat, label: String, target: Bool, window: CGSize?) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(target ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.2), lineWidth: target ? 1.5 : 1))
                if let w = window {
                    VStack(spacing: 0) {
                        HStack(spacing: 3) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 5, height: 5) }; Spacer() }
                            .padding(.horizontal, 5).frame(height: 10).background(Color(white: 0.25))
                        LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.55), Color(red: 0.85, green: 0.4, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .frame(width: w.width, height: w.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(y: target ? 0 : 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: width, height: height)
            .clipped()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// ---- Storage --------------------------------------------------------------------------------------------------------
private struct StorageSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var store = ProfileStore.shared
    @State private var usage: StorageUsage?
    @State private var confirm = false
    @State private var clearError: String?

    var body: some View {
        PageHeader(title: "Storage", subtitle: "What the launcher keeps on this Mac.")
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(Paths.support.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"), systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.support]) }
                }
                if let u = usage {
                    ForEach(u.items, id: \.name) { item in
                        HStack(spacing: 10) {
                            Text(item.name).frame(width: 170, alignment: .leading).lineLimit(1)
                            Meter(fraction: u.total > 0 ? item.bytes / u.total : 0, color: item.color, height: 6)
                            Text(Fmt.size(item.bytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                    Divider()
                    HStack { Text("In all").fontWeight(.semibold); Spacer(); Text(Fmt.size(u.total)).monospacedDigit().fontWeight(.semibold) }
                    if settings.developerMode {
                        Text("The developer checkout's out/ folder is not counted here and is never deleted by the launcher.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                }
            }
        }
        Text("Start over").font(.headline).padding(.top, 6)
        VStack(alignment: .leading, spacing: 10) {
            Text("Deletes everything the launcher keeps and restarts it as new:").font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                bullet("\(store.profiles.count) machine\(store.profiles.count == 1 ? "" : "s") and their disks" + (usage.map { " (\(Fmt.size($0.machines)))" } ?? ""))
                if settings.developerMode {
                    bullet("not the checkout's out/ folder: its images and QEMU stay")
                } else {
                    bullet("the downloaded Linuxes and QEMU" + (usage.map { " (\(Fmt.size($0.downloads)))" } ?? ""))
                }
                bullet("the launcher's settings, saved remote passwords, the browser's data and macOS permissions")
            }
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Clear All Data on This Mac…", role: .destructive) { confirm = true }
            }
            if let clearError { Banner(text: clearError, kind: .error) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.35)))
        .confirmationDialog("Clear all myLinux data on this Mac?", isPresented: $confirm) {
            Button("Delete Everything and Restart", role: .destructive) { clearError = StartOver.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(store.profiles.count) machine\(store.profiles.count == 1 ? "" : "s") with everything inside" + (usage.map { ", \(Fmt.size($0.total)) in all" } ?? "") + ", the downloads and the settings are deleted. This cannot be undone.")
        }
        .task { usage = await StorageUsage.measure(profiles: store.profiles, settings: settings) }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(s).fixedSize(horizontal: false, vertical: true) }
    }
}

/// The space the launcher's things take on the Mac (allocated blocks, so sparse disks count what they hold).
struct StorageUsage {
    struct Item { let name: String; let bytes: Double; let color: Color }
    var items: [Item]
    var machines: Double
    var downloads: Double
    var total: Double { items.reduce(0) { $0 + $1.bytes } }

    static func measure(profiles: [Profile], settings: AppSettings) async -> StorageUsage {
        let out = settings.outDir, dev = settings.developerMode, support = Paths.support
        return await Task.detached(priority: .utility) {
            var items: [Item] = []
            var machines = 0.0
            for p in profiles {
                // a machine's folder, or just its disk when it lives somewhere shared (a checkout's out/)
                let folder = p.machineFolder
                let inside = folder.path.hasPrefix(support.path)
                let b = inside ? allocated(folder) : allocated(URL(fileURLWithPath: p.appsDisk))
                machines += b
                items.append(Item(name: p.name, bytes: b, color: .blue))
            }
            var downloads = 0.0
            if !dev {
                for (name, paths) in [("myLinux image", ["Image", "rootfs.cpio.gz"]), ("Omarchy", ["omarchy"]), ("Debian", ["debian"]),
                                      ("Alpine", ["alpine"]), ("QEMU runtime", ["qemu-runtime", "qemu-runtime.prev"])] {
                    let b = paths.reduce(0.0) { $0 + allocated(out.appendingPathComponent($1)) }
                    if b > 0 { downloads += b; items.append(Item(name: name, bytes: b, color: .purple)) }
                }
            }
            let logs = allocated(Paths.logs)
            if logs > 0 { items.append(Item(name: "Logs", bytes: logs, color: .gray)) }
            return StorageUsage(items: items.sorted { $0.bytes > $1.bytes }, machines: machines, downloads: downloads)
        }.value
    }

    /// A file's or folder's allocated size.
    static func allocated(_ url: URL) -> Double {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func size(_ u: URL) -> Double {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Double(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard isDir.boolValue else { return size(url) }
        var total = 0.0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) {
            for case let u as URL in e { total += size(u) }
        }
        return total
    }
}

// ---- Developer ------------------------------------------------------------------------------------------------------
private struct DeveloperSettingsPage: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        PageHeader(title: "Developer", subtitle: "Run machines from a myLinux source checkout.")
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("myLinux checkout") {
                    HStack {
                        Text(settings.repoPath.isEmpty ? "none" : settings.repoPath)
                            .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseRepo)
                        Button("Clear") { settings.repoPath = "" }.disabled(settings.repoPath.isEmpty)
                    }
                }
                if !settings.repoPath.isEmpty && !settings.developerMode {
                    Banner(text: "That folder has no run.sh and tools/get-image.sh, so it is ignored.", kind: .warning)
                }
            }
        }
        DisclosureGroup("Details") {
            Text("With a checkout, machines start from its run.sh, tools/ and out/, so a locally built image and hot-swapped binaries in share/ are what you get. Without one, the app uses its own copy of the scripts and the downloaded releases.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Pick a myLinux source checkout (the folder with run.sh)."
        if panel.runModal() == .OK, let url = panel.url { settings.repoPath = url.path }
    }
}
