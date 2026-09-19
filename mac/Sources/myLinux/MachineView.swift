import SwiftUI
import AppKit

/// One machine: what it is, how it starts, and its settings. Settings are editable while it is stopped; a running
/// machine shows the console instead.
struct MachineView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var runner: Runner
    @State private var draft: Profile
    @State private var showConsole = false
    @StateObject private var runtime = RuntimeManager.shared
    @StateObject private var omarchy = OmarchyManager.shared
    private var isOmarchy: Bool { draft.kind == .omarchy }
    private var guestName: String { isOmarchy ? "Omarchy" : "myLinux" }

    init(profile: Profile, runner: Runner) {
        self.runner = runner
        _draft = State(initialValue: profile)
    }

    private var editable: Bool { !runner.isActive && runner.state != .inUseElsewhere }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showConsole && (runner.isActive || runner.consoleConnected || !runner.console.isEmpty) {
                ConsoleView(runner: runner)
            } else {
                form
            }
        }
        .onChange(of: draft) { _, new in store.update(new) }
        .onAppear { if isOmarchy { runtime.refresh(settings); omarchy.refresh(settings) } }
        .onChange(of: runner.state) { _, new in
            if new == .running { showConsole = false }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("", selection: $showConsole) {
                    Text("Settings").tag(false)
                    Text("Console").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!runner.isActive && !runner.consoleConnected && runner.console.isEmpty)
            }
        }
    }

    // ---- header: name, state, start/stop ------------------------------------------------------------------
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Name", text: $draft.name)
                    .textFieldStyle(.plain).font(.title2.bold())
                    .disabled(!editable)
                    .frame(maxWidth: 320)
                Spacer()
                switch runner.state {
                case .stopped, .failed:
                    Button { runner.start(draft, settings: settings) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.problems.isEmpty)
                case .starting:
                    ProgressView().controlSize(.small)
                    Button("Force Quit", role: .destructive) { runner.forceQuit() }
                case .running:
                    Button { runner.stop() } label: { Label("Shut Down", systemImage: "power") }
                        .buttonStyle(.borderedProminent)
                case .stopping:
                    ProgressView().controlSize(.small)
                    Text("Shutting down…").foregroundStyle(.secondary)
                    Button("Force Quit", role: .destructive) { runner.forceQuit() }
                case .inUseElsewhere:
                    Text(runner.consoleConnected ? "Started outside this launcher" : "Running outside the app").foregroundStyle(.secondary)
                    if runner.consoleConnected {
                        Button { runner.stop() } label: { Label("Shut Down", systemImage: "power") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Force Quit", role: .destructive) { runner.forceQuit() }
                }
            }
            if case .failed(let message) = runner.state {
                HStack(alignment: .top) {
                    Banner(text: message, kind: .error)
                    Spacer()
                    Button("Show Log") { NSWorkspace.shared.open(runner.logFile) }.buttonStyle(.link).font(.caption)
                }
            }
            if let first = draft.problems.first, editable {
                Banner(text: first, kind: .warning)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // ---- settings ---------------------------------------------------------------------------------------------
    private var form: some View {
        Form {
            if isOmarchy { omarchyDownloads }
            Section(isOmarchy ? "Keyboard" : "Keyboard and mouse") {
                Picker("Mac keys", selection: $draft.grab) {
                    Text(isOmarchy ? "Option is Super inside Omarchy" : "Option is ⌘ inside myLinux").tag("opt")
                    Text("Send every key to \(guestName)").tag("full")
                    Text("Leave Mac shortcuts alone").tag("none")
                }
                Text(grabHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !isOmarchy {
                    Picker("Pointer", selection: $draft.mouse) {
                        Text("Follows the Mac pointer").tag("tablet")
                        Text("Captured on click (Ctrl+Option+G frees it)").tag("relative")
                    }
                    Toggle("Share the Mac clipboard", isOn: $draft.clipboard)
                }
            }
            Section("Machine") {
                Picker("Memory", selection: $draft.memoryGB) {
                    ForEach(memoryChoices, id: \.self) { Text("\($0) GB").tag($0) }
                }
                Picker("Screen", selection: Binding(
                    get: { draft.resolution.isEmpty },
                    set: { draft.resolution = $0 ? "" : (draft.resolution.isEmpty ? "1600x1000" : draft.resolution) })) {
                    Text("Fit the Mac screen").tag(true)
                    Text("Fixed size").tag(false)
                }
                if !draft.resolution.isEmpty {
                    LabeledContent("Size") {
                        HStack {
                            TextField("", text: $draft.resolution).frame(width: 110).multilineTextAlignment(.trailing)
                            Text("pixels, for example 1920x1200").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent(isOmarchy ? "Disk size" : "Apps disk size") {
                    HStack {
                        Picker("", selection: $draft.appsSizeGB) {
                            ForEach(isOmarchy ? [16, 32, 64, 128, 256, 512] : [8, 16, 32, 64, 128, 256], id: \.self) { Text("\($0) GB").tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                        Text(diskNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Files") {
                if isOmarchy {
                    PathRow(title: "Disk", path: $draft.appsDisk, isDirectory: false,
                            help: "The whole Omarchy install. Its kernel lives in the boot folder beside it, so keep the two together.")
                    PathRow(title: "Share folder", path: $draft.shareDir, isDirectory: true,
                            help: "Shows up inside Omarchy as a folder of the same name in your home folder. Leave empty for none.")
                } else {
                    PathRow(title: "Apps disk", path: $draft.appsDisk, isDirectory: false,
                            help: "Everything you install inside myLinux. A separate disk is a separate install.")
                    PathRow(title: "Share folder", path: $draft.shareDir, isDirectory: true,
                            help: "Visible as /mnt/share inside myLinux, and where its settings live.")
                }
            }
            Section {
                LabeledContent("Window title") { Text(draft.windowName).foregroundStyle(.secondary) }
                LabeledContent("Log") {
                    Button("Show Log") { NSWorkspace.shared.open(runner.logFile) }
                        .buttonStyle(.link)
                        .disabled(!FileManager.default.fileExists(atPath: runner.logFile.path))
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!editable)
    }

    /// What an Omarchy machine needs before its first start, each with its own download.
    @ViewBuilder private var omarchyDownloads: some View {
        let needRuntime = !runtime.present, needGuest = !omarchy.present && !FileManager.default.fileExists(atPath: draft.appsDisk)
        if needRuntime || needGuest || runtime.busy || omarchy.busy || runtime.lastError != nil || omarchy.lastError != nil {
            Section("Before the first start") {
                if needRuntime || runtime.busy {
                    downloadRow(title: "Accelerated QEMU", detail: "about 10 MB", busy: runtime.busy, progress: runtime.progress,
                                start: { runtime.download(settings) }, cancel: { runtime.cancel() })
                }
                if let e = runtime.lastError { Banner(text: e, kind: .error) }
                if needGuest || omarchy.busy {
                    downloadRow(title: "Omarchy", detail: "1.4 GB, from the Try Omarchy project's signed release", busy: omarchy.busy, progress: omarchy.progress,
                                start: { omarchy.download(settings) }, cancel: { omarchy.cancel() })
                }
                if let e = omarchy.lastError { Banner(text: e, kind: .error) }
            }
        }
    }

    private func downloadRow(title: String, detail: String, busy: Bool, progress: String, start: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel", action: cancel)
                } else {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Button("Download", action: start)
                }
            }
        }
    }

    private var grabHelp: String {
        if isOmarchy {
            switch draft.grab {
            case "full": return "Omarchy receives every key, ⌘ as Super, even ⌘Space and ⌘Tab. macOS asks for Accessibility permission the first time, and Ctrl+Option+G hands the keyboard back."
            case "none": return "macOS keeps all its shortcuts; Omarchy only sees combinations macOS does not claim."
            default: return "The Option key acts as Super inside Omarchy (Option+Space opens the Omarchy menu, Option+Return a terminal). macOS keeps its own ⌘ shortcuts."
            }
        }
        switch draft.grab {
        case "full": return "myLinux receives even ⌘Space and ⌘Tab. macOS asks for Accessibility permission the first time, and Ctrl+Option+G hands the keyboard back."
        case "none": return "macOS keeps all its shortcuts; myLinux only sees combinations macOS does not claim."
        default: return "The Option key acts as ⌘/Super inside myLinux (Option+Space opens the menu). macOS keeps its own ⌘ shortcuts, including ⌘Space for Spotlight."
        }
    }

    private var memoryChoices: [Int] {
        let physical = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        return [2, 4, 6, 8, 12, 16, 24, 32, 48, 64].filter { $0 <= max(4, physical - 2) }
    }

    private var diskNote: String {
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: draft.appsDisk)[.size] as? NSNumber {
            let gb = size.int64Value / (1024 * 1024 * 1024)
            return "the disk already exists (\(gb) GB); the size applies to new disks"
        }
        return isOmarchy ? "unpacked from the download on first start, growing as it fills" : "created on first start, growing as it fills"
    }
}

/// A file or folder setting with a Choose… button and Finder access.
private struct PathRow: View {
    let title: String
    @Binding var path: String
    let isDirectory: Bool
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Text(display).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        .help(path)
                    Button("Choose…", action: choose)
                    Button { reveal() } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                        .disabled(!FileManager.default.fileExists(atPath: path))
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var display: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func choose() {
        if isDirectory {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            if panel.runModal() == .OK, let url = panel.url { path = url.path }
        } else {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            panel.message = "Pick an existing apps disk, or a name for a new one."
            if panel.runModal() == .OK, let url = panel.url { path = url.path }
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
