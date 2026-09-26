import SwiftUI
import AppKit

/// One machine: what it is, how it starts, and its settings. Settings are editable while it is stopped; a running
/// machine shows the console instead.
struct MachineView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var runner: Runner
    @State private var draft: Profile
    @StateObject private var runtime = RuntimeManager.shared
    @StateObject private var omarchy = OmarchyManager.shared
    @StateObject private var debian = ServerImageManager.debian
    @StateObject private var alpine = ServerImageManager.alpine
    @StateObject private var images = ImageManager.shared
    private var isOmarchy: Bool { draft.kind == .omarchy }
    private var isServer: Bool { draft.isServer }
    private var guestName: String { draft.kind.title }
    /// A server's download: Debian's image or Alpine's.
    private var server: ServerImageManager { draft.kind == .alpine ? alpine : debian }

    init(profile: Profile, runner: Runner) {
        self.runner = runner
        _draft = State(initialValue: profile)
    }

    private var editable: Bool { !runner.isActive && runner.state != .inUseElsewhere }

    /// What has to be downloaded before this machine can start, or nil. An existing machine has its own disk and
    /// needs no download; a new one needs its guest, and Omarchy the accelerated QEMU.
    private var missingBeforeStart: String? {
        switch draft.kind {
        case .mylinux:
            return images.present ? nil : (settings.developerMode ? "Build the image first (./build.sh)" : "Download myLinux first")
        case .omarchy:
            let created = FileManager.default.fileExists(atPath: draft.appsDisk) && FileManager.default.fileExists(atPath: draft.machineFolder.appendingPathComponent("boot/vmlinuz-linux").path)
            if !runtime.present { return "Download the accelerated QEMU first" }
            return created || omarchy.present ? nil : "Download Omarchy first"
        case .debian, .alpine:
            let created = FileManager.default.fileExists(atPath: draft.appsDisk) && FileManager.default.fileExists(atPath: draft.machineFolder.appendingPathComponent("seed.iso").path)
            if !settings.qemuAvailable { return "Download the accelerated QEMU first" }
            return created || server.present ? nil : "Download \(guestName) first"
        }
    }

    /// The download the header offers in place of Start while something is missing: its button title, whether it
    /// is under way, its progress line, and how to start it. The same downloads as "Before the first start" below,
    /// where they were easy to miss beside a greyed-out Start and "Download … first".
    private var headerDownload: (name: String, loader: ScriptDownloader, start: () -> Void)? {
        switch draft.kind {
        case .mylinux:
            guard !images.present, !settings.developerMode else { return nil }
            return ("myLinux", images, { images.download(settings) })
        case .omarchy:
            if !runtime.present { return ("QEMU", runtime, { runtime.download(settings) }) }
            let created = FileManager.default.fileExists(atPath: draft.appsDisk) && FileManager.default.fileExists(atPath: draft.machineFolder.appendingPathComponent("boot/vmlinuz-linux").path)
            return created || omarchy.present ? nil : ("Omarchy", omarchy, { omarchy.download(settings) })
        case .debian, .alpine:
            if !settings.qemuAvailable { return ("QEMU", runtime, { runtime.download(settings) }) }
            let created = FileManager.default.fileExists(atPath: draft.appsDisk) && FileManager.default.fileExists(atPath: draft.machineFolder.appendingPathComponent("seed.iso").path)
            return created || server.present ? nil : (guestName, server, { server.download(settings) })
        }
    }

    // the three folding parts of the page, open or closed as last left
    @AppStorage("fold.configuration") private var openConfig = false
    @AppStorage("fold.files") private var openFiles = false
    @AppStorage("fold.diagnostics") private var openDiagnostics = false
    @ObservedObject private var stats = MachineStats.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                if MachineStatus.running(runner) {
                    Section {} header: { live }
                }
                if isServer { serverDownloads } else if isOmarchy { omarchyDownloads }
                Section {} header: { fold("Machine configuration", "slider.horizontal.3", configSummary, $openConfig) }
                if openConfig {
                    Group { if isServer { serverConfiguration } else { desktopConfiguration } }.disabled(!editable)
                }
                Section {} header: { fold("Files & sharing", "folder", filesSummary, $openFiles) }
                if openFiles { files.disabled(!editable) }
                Section {} header: { fold("Console & diagnostics", "terminal", diagnosticsSummary, $openDiagnostics) }
                if openDiagnostics { diagnostics }
            }
            .formStyle(.grouped)
        }
        .onChange(of: draft) { _, new in store.update(new) }
        .onAppear { runtime.refresh(settings); images.refresh(settings); if isOmarchy { omarchy.refresh(settings) }; if isServer { server.refresh(settings) } }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { VersionAndSettings() } }
    }

    // ---- header: icon, name, state, actions ------------------------------------------------------------------------
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                MachineIconView(kind: draft.kind, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    // renamed while stopped; a running machine's name is plain text, not a greyed-out field
                    if editable {
                        TextField("Name", text: $draft.name)
                            .textFieldStyle(.plain).font(.title2.bold())
                            .frame(maxWidth: 320)
                    } else {
                        Text(draft.name).font(.title2.bold()).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(MachineStatus.color(runner)).frame(width: 7, height: 7)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(MachineStatus.text(draft, runner, now: ctx.date)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        }
                    }
                    .font(.callout)
                }
                Spacer(minLength: 12)
                actions
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color.accentColor.opacity(0.10), Color.primary.opacity(0.03)],
                                                                      startPoint: .leading, endPoint: .trailing)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            if case .failed(let message) = runner.state {
                HStack(alignment: .top) {
                    Banner(text: message, kind: .error)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Show Log") { NSWorkspace.shared.open(runner.logFile) }.buttonStyle(.link).font(.caption)
                }
            }
            if let first = draft.problems.first, editable {
                Banner(text: first, kind: .warning)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch runner.state {
            case .stopped, .failed:
                if let d = headerDownload {
                    // what is missing, as the button where Start will be
                    if d.loader.busy {
                        ProgressView().controlSize(.small)
                        // "Downloading Debian · 51.5% · 12 s": the percentage the script prints, and the clock
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let pct = d.loader.progress.range(of: #"[0-9.]+%"#, options: .regularExpression).map { " · " + d.loader.progress[$0] } ?? ""
                            Text("Downloading \(d.name)\(pct) · \(Runner.seconds(ctx.date.timeIntervalSince(d.loader.startedAt ?? ctx.date)))")
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Button { d.start() } label: { Label("Download \(d.name)", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(.borderedProminent)
                            .help("Downloads once; then Start is here")
                    }
                } else {
                    if let missing = missingBeforeStart { Text(missing).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing) }
                    Button { runner.start(draft, settings: settings) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.problems.isEmpty || missingBeforeStart != nil)
                }
            case .starting:
                ProgressView().controlSize(.small)
                Button("Force Quit", role: .destructive) { runner.forceQuit() }
            case .running:
                if isServer {
                    if runner.waitingForSSH {
                        ProgressView().controlSize(.small)
                        Button {} label: { Label(runner.mountingCloud ? "Connecting folders…" : "Waiting for SSH…", systemImage: "terminal") }
                            .disabled(true)
                            .help("The terminal opens as soon as the machine answers.")
                    } else {
                        Button { openTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button { runner.stop() } label: { Label("Shut Down", systemImage: "power") }
                } else {
                    Button { showWindow() } label: { Label("Show Window", systemImage: "macwindow") }
                        .buttonStyle(.borderedProminent)
                    Button { runner.stop() } label: { Label("Shut Down", systemImage: "power") }
                }
            case .stopping:
                ProgressView().controlSize(.small)
                Button("Force Quit", role: .destructive) { runner.forceQuit() }
            case .inUseElsewhere where isServer:
                // started by an earlier launcher (updated or restarted since): still reachable over SSH and QMP
                if runner.waitingForSSH {
                    ProgressView().controlSize(.small)
                } else {
                    Button { openTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                        .buttonStyle(.borderedProminent)
                }
                Button { runner.stop() } label: { Label("Shut Down", systemImage: "power") }
                Button("Force Quit", role: .destructive) { runner.forceQuit() }
            case .inUseElsewhere:
                Button { showWindow() } label: { Label("Show Window", systemImage: "macwindow") }
                if runner.consoleConnected {
                    Button { runner.stop() } label: { Label("Shut Down", systemImage: "power") }
                        .buttonStyle(.borderedProminent)
                }
                Button("Force Quit", role: .destructive) { runner.forceQuit() }
            }
        }
    }

    /// A desktop's window: its own app (MachineApp), or any myLinux desktop from before 0.6.
    private func showWindow() {
        if let app = MachineApp.running(draft) { app.activate(); return }
        let prefix = isOmarchy ? "dev.mylinux.vm.omarchy" : "dev.mylinux.vm"
        NSWorkspace.shared.runningApplications.first { ($0.bundleIdentifier ?? "").hasPrefix(prefix) }?.activate()
    }

    // ---- live: the last minute, and how to reach it ------------------------------------------------------------------
    private var live: some View {
        let s = stats.stats[draft.id]
        let h = stats.history[draft.id] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live activity").font(.headline).foregroundStyle(.primary)
                Spacer()
                Text("Last 60 seconds").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                StatCard(symbol: "cpu", title: "CPU usage", value: s.map { "\(Int(($0.cpu * 100).rounded()))" } ?? "—", unit: "%",
                         caption: s.map { "of its \($0.vcpus) cores" } ?? "measuring…") {
                    Sparkline(values: h.map(\.cpu), color: .blue)
                }
                StatCard(symbol: "memorychip", title: "Memory usage", value: s.map { "\(Int(($0.memFraction * 100).rounded()))" } ?? "—", unit: "%",
                         caption: s.map { "\(Fmt.gb($0.memUsed)) of \(Fmt.gb($0.memTotal)) GB in use" } ?? "measuring…") {
                    Sparkline(values: h.map(\.mem), color: .purple)
                }
                StatCard(symbol: "internaldrive", title: "Disk space", value: s.map { Fmt.gb($0.diskFree) } ?? "—", unit: "GB free",
                         caption: s.map { "\(Fmt.gb($0.diskTotal)) GB disk" } ?? "measuring…") {
                    // as tall as a graph with its captions, so the three cards line up
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer(minLength: 0)
                        Meter(fraction: s?.diskFraction ?? 0, color: .blue)
                        Text(s.map { "≈ \(Fmt.gb($0.diskUsed)) GB used" } ?? " ").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(height: Sparkline.height)
                }
            }
            if let c = connection {
                Text("Connection").font(.headline).foregroundStyle(.primary).padding(.top, 6)
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(c.command).font(.callout.monospaced()).textSelection(.enabled)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                            Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isServer {
                            if runner.sshReady {
                                Label("SSH ready", systemImage: "checkmark").foregroundStyle(.green).font(.callout)
                            } else if runner.waitingForSSH {
                                Label("Waiting for SSH…", systemImage: "hourglass").foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                }
            }
        }
        .textCase(nil)
        .font(.body)
        .padding(.bottom, 6)
    }

    /// How to reach the machine from the Mac's own terminal: a server always, Omarchy when SSH is on.
    private var connection: (command: String, detail: String)? {
        if isServer {
            return ("ssh -p \(String(draft.sshPort)) \(draft.kind.serverUser)@127.0.0.1", "This Mac only · the machine's own SSH key (ssh_key in its folder)")
        }
        if isOmarchy, draft.sshPort != 0 {
            return ("ssh -p \(String(draft.sshPort)) <your Omarchy user>@127.0.0.1", "This Mac only · the account you made in Omarchy")
        }
        return nil
    }

    // ---- the folding parts ---------------------------------------------------------------------------------------------
    private func fold(_ title: String, _ symbol: String, _ summary: String, _ open: Binding<Bool>) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { open.wrappedValue.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title).font(.headline).foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Spacer()
                if !open.wrappedValue { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    private var configSummary: String {
        var parts = ["\(draft.memoryGB) GB", draft.cpus == 0 ? "automatic cores" : "\(draft.cpus) cores"]
        if isServer { parts.append("port \(String(draft.sshPort))") }
        else { parts.append(draft.grab == "opt" ? "Option as ⌘" : draft.grab == "full" ? "all keys" : "no key grab") }
        return parts.joined(separator: " · ")
    }
    private var filesSummary: String {
        let disk = URL(fileURLWithPath: draft.appsDisk).lastPathComponent
        return draft.shareDir.isEmpty ? "\(disk) · no share" : "\(disk) · share: \(URL(fileURLWithPath: draft.shareDir).lastPathComponent)"
    }
    private var diagnosticsSummary: String { runner.consoleConnected ? "console connected · log" : "log" }

    /// A server: no window, no keyboard settings; the terminal is the machine.
    @ViewBuilder private var serverConfiguration: some View {
        Section("Machine") {
            memoryPicker
            Picker("Processor cores", selection: $draft.cpus) {
                Text("Automatic").tag(0)
                ForEach(coreChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            LabeledContent("Disk size") {
                HStack {
                    Picker("", selection: $draft.appsSizeGB) {
                        ForEach([16, 32, 64, 128, 256, 512], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                    Text("copied from the image on first start, growing as it fills").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Terminal") {
            LabeledContent("SSH port on this Mac") {
                HStack {
                    TextField("", value: $draft.sshPort, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                    Text("ssh -p \(String(draft.sshPort)) \(draft.kind.serverUser)@127.0.0.1").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Text(draft.kind == .alpine
                 ? "The Terminal button opens an SSH terminal with the key made for this machine (ssh_key in its folder). The account is Alpine's own \"alpine\", with doas for root (Install Script… adds bash); reachable from this Mac only."
                 : "The Terminal button opens an SSH terminal with the key made for this machine (ssh_key in its folder). The account is \"debian\" with sudo; reachable from this Mac only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var files: some View {
        Section {
            if isServer {
                PathRow(title: "Disk", path: $draft.appsDisk, isDirectory: false,
                        help: "The whole \(guestName) install. Its SSH key, console password and cloud-init seed live in the same folder.")
                PathRow(title: "Share folder", path: $draft.shareDir, isDirectory: true,
                        help: "Mounted inside as /mnt/mac and linked from the home folder under its own name. Leave empty for none.")
            } else if isOmarchy {
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
    }

    @ViewBuilder private var diagnostics: some View {
        if runner.isActive || runner.consoleConnected || !runner.console.isEmpty {
            Section {
                ConsoleView(runner: runner).frame(height: 300)
            }
        }
        Section {
            if isServer {
                LabeledContent("Host name") { Text(draft.name).foregroundStyle(.secondary) }
                if let pw = consolePassword {
                    LabeledContent("Console login") {
                        Text("\(draft.kind.serverUser) / \(pw)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("For the serial console above when SSH is not up; made on the first start.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Window title") { Text(draft.windowName).foregroundStyle(.secondary) }
            }
            LabeledContent("Log") {
                Button("Show Log") { NSWorkspace.shared.open(runner.logFile) }
                    .buttonStyle(.link)
                    .disabled(!FileManager.default.fileExists(atPath: runner.logFile.path))
            }
        }
    }

    private var consolePassword: String? {
        (try? String(contentsOf: draft.machineFolder.appendingPathComponent("console-password"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The SSH terminal to this machine: an unsaved remote profile keyed by the machine's id, so a second click
    /// brings the same window forward.
    private func openTerminal() { runner.openTerminal(draft) }

    /// What a server needs before its first start.
    @ViewBuilder private var serverDownloads: some View {
        let needQemu = !settings.qemuAvailable
        let needImage = !server.present && !FileManager.default.fileExists(atPath: draft.appsDisk)
        if needQemu || needImage || runtime.busy || server.busy || runtime.lastError != nil || server.lastError != nil {
            Section("Before the first start") {
                if needQemu || runtime.busy {
                    downloadRow(title: "Accelerated QEMU", detail: "about 10 MB", busy: runtime.busy, progress: runtime.progress,
                                start: { runtime.download(settings) }, cancel: { runtime.cancel() })
                }
                if let e = runtime.lastError { Banner(text: e, kind: .error) }
                if needImage || server.busy {
                    downloadRow(title: guestName, detail: server.detail, busy: server.busy, progress: server.progress,
                                start: { server.download(settings) }, cancel: { server.cancel() })
                }
                if let e = server.lastError { Banner(text: e, kind: .error) }
            }
        }
    }

    @ViewBuilder private var desktopConfiguration: some View {
        Section(isOmarchy ? "Keyboard" : "Keyboard and mouse") {
            Picker(isOmarchy ? "Super key" : "Mac keys", selection: $draft.grab) {
                Text(isOmarchy ? "Option (macOS keeps its ⌘ shortcuts)" : "Option is ⌘ inside myLinux").tag("opt")
                Text(isOmarchy ? "Command (every key goes to Omarchy)" : "Send every key to myLinux").tag("full")
                Text(isOmarchy ? "None (Mac shortcuts untouched)" : "Leave Mac shortcuts alone").tag("none")
            }
            Text(grabHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !isOmarchy {
                Picker("Pointer", selection: $draft.mouse) {
                    Text("Follows the Mac pointer").tag("tablet")
                    Text("Captured on click (Ctrl+Option+G frees it)").tag("relative")
                }
            }
            Toggle("Share the Mac clipboard", isOn: $draft.clipboard)
            if isOmarchy {
                Text("Text and images, both ways, through Omarchy's own clipboard agent.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Machine") {
            memoryPicker
            if isOmarchy {
                Picker("Processor cores", selection: $draft.cpus) {
                    Text("Automatic").tag(0)
                    ForEach(coreChoices, id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Picker("Screen", selection: screenChoice) {
                Text("Fit the Mac screen").tag("")
                ForEach(MachineView.screenSizes, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                Text("Custom size").tag("custom")
            }
            if screenChoice.wrappedValue == "custom" {
                LabeledContent("Size") {
                    HStack {
                        TextField("", text: $draft.resolution).frame(width: 110).multilineTextAlignment(.trailing)
                        Text("pixels, for example 1920x1200").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if isOmarchy {
                Text("The window opens at exactly this size and is not resizable; the green button gives full screen. Sizes are in points: a Retina MacBook screen is about 1728 × 1084, not its pixel count.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        if isOmarchy {
            Section("Sound and network") {
                Toggle("Sound through the Mac", isOn: $draft.sound)
                Toggle("SSH from the Mac", isOn: Binding(get: { draft.sshPort != 0 }, set: { draft.sshPort = $0 ? 2222 : 0 }))
                if draft.sshPort != 0 {
                    LabeledContent("Port on this Mac") {
                        HStack {
                            TextField("", value: $draft.sshPort, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                            Text("ssh -p \(String(draft.sshPort)) <your Omarchy user>@127.0.0.1").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Text("Reachable from this Mac only. Omarchy starts its SSH server for this boot; log in with the account you made in Omarchy.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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

    static let screenSizes = ["1280x800", "1440x900", "1600x1000", "1920x1080", "1920x1200", "2560x1440"]
    /// "" fits the screen, a listed size is itself, anything else typed is "custom".
    private var screenChoice: Binding<String> {
        Binding(get: { draft.resolution.isEmpty ? "" : (MachineView.screenSizes.contains(draft.resolution.lowercased()) ? draft.resolution.lowercased() : "custom") },
                set: { draft.resolution = $0 == "custom" ? "1700x1050" : $0 })
    }
    private var coreChoices: [Int] {
        let n = ProcessInfo.processInfo.processorCount
        return [2, 4, 6, 8, 10, 12, 16].filter { $0 <= n }
    }

    private var memoryChoices: [Int] {
        [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64].filter { $0 >= (isServer ? 1 : 2) && $0 <= max(4, Profile.macMemoryGB - 2) }
    }
    /// Automatic (0 here) follows the Mac's memory at every launcher start; a size is kept as chosen.
    private var memoryPicker: some View {
        let recommended = Profile.recommendedMemoryGB(draft.kind)
        return Picker("Memory", selection: Binding(
            get: { draft.memoryAuto ? 0 : draft.memoryGB },
            set: { v in draft.memoryAuto = v == 0; draft.memoryGB = v == 0 ? recommended : v })) {
            Text("Automatic (\(recommended) GB on this \(Profile.macMemoryGB) GB Mac)").tag(0)
            Divider()
            ForEach(memoryChoices, id: \.self) { Text("\($0) GB").tag($0) }
        }
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
