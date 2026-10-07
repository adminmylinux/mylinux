import SwiftUI
import AppKit

/// The launcher's Settings: a category list on the left (Terminal, Images & runtime, Windows, Storage, Updates, Developer)
/// and one page at a time, each short, with the technical details folded under "Details".
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case terminal, images, windows, storage, updates, developer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .terminal: return "Terminal"
            case .images: return "Images & runtime"
            case .windows: return "Windows"
            case .storage: return "Storage"
            case .updates: return "Updates"
            case .developer: return "Developer"
            }
        }
        var symbol: String {
            switch self {
            case .terminal: return "terminal"
            case .images: return "shippingbox"
            case .windows: return "macwindow.on.rectangle"
            case .storage: return "internaldrive"
            case .updates: return "arrow.down.circle"
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
                    case .updates: UpdatesSettingsPage()
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
    @AppStorage(SpaceHotkey.settingKey) private var cmdSpace = true
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        PageHeader(title: "Terminal", subtitle: "For Debian, Alpine and SSH connections: Ghostty, GPU accelerated.")
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

    /// A drawn sample of the terminal's look (not a live terminal), with its keys.
    private var preview: some View {
        let mono = Font.custom("JetBrains Mono", size: 12.5).monospaced()
        let prompt = Color(red: 0.55, green: 0.85, blue: 0.62)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("›_  debian — ~").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Ghostty").font(.caption).foregroundStyle(.secondary)
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
            .background(Color(red: 0.11, green: 0.12, blue: 0.14))
            Divider()
            HStack(spacing: 8) {
                KeyCap(text: "⌘C"); Text("Copy")
                KeyCap(text: "⌘V"); Text("Paste")
                KeyCap(text: "⌘ + / −"); Text("Text size")
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
    @StateObject private var omarchy = DesktopImageManager.omarchy
    @StateObject private var arch = DesktopImageManager.arch
    @StateObject private var debian = ServerImageManager.debian
    @StateObject private var alpine = ServerImageManager.alpine
    @StateObject private var tiny = ServerImageManager.tiny
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
            row(icon: MachineIcon.image(.arch), name: "Arch Linux", size: "2 GB", loader: arch,
                status: arch.present ? "Installed · \(arch.revision ?? "")" : nil,
                action: arch.present ? "Update" : "Download", start: { arch.download(settings) })
            Divider()
            row(icon: MachineIcon.image(.debian), name: "Debian", size: "300 MB", loader: debian,
                status: debian.present ? "Installed · \(debian.revision ?? "")" : nil,
                action: debian.present ? "Update" : "Download", start: { debian.download(settings) })
            Divider()
            row(icon: MachineIcon.image(.alpine), name: "Alpine", size: "100 MB", loader: alpine,
                status: alpine.present ? "Installed · \(alpine.revision ?? "")" : nil,
                action: alpine.present ? "Update" : "Download", start: { alpine.download(settings) })
            Divider()
            row(icon: MachineIcon.image(.tiny), name: "Tiny Alpine", size: "18 MB", loader: tiny,
                status: tiny.present ? "Installed · \(tiny.revision ?? "")" : nil,
                action: tiny.present ? "Update" : "Download", start: { tiny.download(settings) })
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
                     : "myLinux's own QEMU with GPU support (VirGL, drawn through Metal), about 15 MB, no Homebrew needed. Machines use it from their next start. Its sources and licences are in the runtime's NOTICES.md.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if runtime.present, !runtime.busy { Button("Remove the runtime") { runtime.remove(settings) } }
            }
            .padding(.top, 6)
        }
        .onAppear { images.refresh(settings); omarchy.refresh(settings); arch.refresh(settings); debian.refresh(settings); alpine.refresh(settings); tiny.refresh(settings); runtime.refresh(settings) }
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

// ---- Updates --------------------------------------------------------------------------------------------------------
private struct UpdatesSettingsPage: View {
    @ObservedObject private var updater = LauncherUpdater.shared

    var body: some View {
        PageHeader(title: "Updates", subtitle: "The launcher updates itself from myLinux's releases.")
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("myLinux Launcher").fontWeight(.semibold)
                        Text(LauncherUpdater.currentVersion.isEmpty ? "Development build" : "Version \(LauncherUpdater.currentVersion)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    button
                }
                status
            }
        }
        if let why = LauncherUpdater.cannotReplace() {
            Banner(text: why, kind: .warning)
        } else {
            Text("Machines keep running while the launcher updates: the new launcher opens and takes over their windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Color.clear.frame(height: 0).onAppear {
            // a fresh look each time the page opens, unless one is under way or was just made
            let recent = updater.checkedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
            switch updater.state {
            case .idle, .failed: updater.check()
            case .upToDate, .available: if !recent { updater.check() }
            default: break
            }
        }
    }

    @ViewBuilder private var button: some View {
        switch updater.state {
        case .available(let r):
            Button("Update to \(r.version)") { updater.update(to: r) }
                .buttonStyle(.borderedProminent).disabled(LauncherUpdater.cannotReplace() != nil)
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check for Updates") { updater.check() }
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle, .checking:
            Text("Looking for a newer version…").font(.callout).foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date" + (updater.checkedAt.map { ", checked \($0.formatted(date: .omitted, time: .shortened))" } ?? ""), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .available(let r):
            VStack(alignment: .leading, spacing: 8) {
                Label("Version \(r.version) is available" + (r.size.map { " · \(Fmt.size(Double($0)))" } ?? ""), systemImage: "arrow.down.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                if let notes = r.notes, !notes.isEmpty {
                    ScrollView {
                        Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes))
                            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
            }
        case .downloading(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                if total > 0 { ProgressView(value: Double(done), total: Double(total)) } else { ProgressView() }
                Text("Downloading \(Fmt.size(Double(done)))" + (total > 0 ? " of \(Fmt.size(Double(total)))" : "") + "…")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .installing:
            Text("Installing; the launcher opens again in a moment…").font(.callout).foregroundStyle(.secondary)
        case .failed(let why):
            Banner(text: why, kind: .error)
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
    @State private var saved: [SavedDownloads.Item]?
    @State private var confirmRemoveSaved = false
    @State private var savedError: String?

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
        if !settings.developerMode {
            Text("Saved downloads").font(.headline).padding(.top, 6)
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Each Linux is kept as downloaded, so a new machine installs it in seconds without a download, also after Clear All Data. When a newer version is out, the launcher asks which one to install. The saved copies share disk space with the installed ones.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let saved {
                        if saved.isEmpty {
                            Text("Nothing is saved yet: a Linux is saved when it is downloaded.").font(.callout)
                        }
                        ForEach(saved, id: \.name) { item in
                            HStack(spacing: 10) {
                                Text(item.name).frame(width: 170, alignment: .leading)
                                Text(item.revision).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(Fmt.size(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        if !saved.isEmpty {
                            HStack {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.downloadCache]) }
                                Spacer()
                                Button("Remove Saved Downloads…", role: .destructive) { confirmRemoveSaved = true }
                            }
                        }
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                    }
                    if let savedError { Banner(text: savedError, kind: .error) }
                }
            }
            .confirmationDialog("Remove the saved downloads?", isPresented: $confirmRemoveSaved) {
                Button("Remove", role: .destructive) {
                    savedError = SavedDownloads.removeAll()
                    Task { saved = await Task.detached(priority: .utility) { SavedDownloads.list() }.value }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Installed Linuxes and machines stay. The next install of a Linux downloads it again.")
            }
            .task { saved = await Task.detached(priority: .utility) { SavedDownloads.list() }.value }
        }
        Text("Start over").font(.headline).padding(.top, 6)
        VStack(alignment: .leading, spacing: 10) {
            Text("Deletes everything the launcher keeps and restarts it as new:").font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                bullet("\(store.profiles.count) machine\(store.profiles.count == 1 ? "" : "s") and their disks" + (usage.map { " (\(Fmt.size($0.machines)))" } ?? ""))
                if settings.developerMode {
                    bullet("not the checkout's out/ folder: its images and QEMU stay")
                } else {
                    bullet("the installed Linuxes and QEMU" + (usage.map { " (\(Fmt.size($0.downloads)))" } ?? ""))
                    bullet("not the saved downloads above: machines install again from them, without a download")
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
            Text(clearMessage)
        }
        .task { usage = await StorageUsage.measure(profiles: store.profiles, settings: settings) }
    }

    private var clearMessage: String {
        let n = store.profiles.count
        let total: String = usage.map { ", \(Fmt.size($0.total)) in all" } ?? ""
        let kept: String = settings.developerMode ? "" : "; the saved downloads stay"
        return "\(n) machine\(n == 1 ? "" : "s") with everything inside\(total), the installed Linuxes and the settings are deleted\(kept). This cannot be undone."
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
                for (name, paths) in [("myLinux image", ["Image", "rootfs.cpio.gz"]), ("Omarchy", ["omarchy"]), ("Arch Linux", ["arch"]), ("Debian", ["debian"]),
                                      ("Alpine", ["alpine"]), ("Tiny Alpine", ["tiny"]), ("QEMU runtime", ["qemu-runtime", "qemu-runtime.prev"])] {
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
