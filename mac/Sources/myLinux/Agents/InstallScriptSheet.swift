import SwiftUI
import AppKit

/// The Install Script dialog. Install: the machine's install script (debian_install.sh, alpine_install.sh) as loaded
/// from GitHub, a checkbox for each of its options, and the text itself to read or change; Run copies the text into
/// the machine and runs it in the terminal, in view. Cloud: the Mac's cloud folders to have inside, beside ~/Mac.
struct InstallScriptSheet: View {
    enum Tab: String { case install, cloud }
    let profile: RemoteProfile
    let dismiss: () -> Void
    /// Called once the script is in the machine, with the command the window types into the terminal.
    let run: (String) -> Void
    /// Called when saving cloud folders restarts the machine (the window then shows the restart's progress).
    var restarting: () -> Void = {}
    @StateObject private var loader: InstallScriptLoader
    @State private var uploading = false
    @State private var problem: String?
    @State private var tab: Tab

    /// `preset`, for pictures of the dialog: start with this text instead of loading it.
    init(profile: RemoteProfile, dismiss: @escaping () -> Void, run: @escaping (String) -> Void, restarting: @escaping () -> Void = {},
         preset: String? = nil, tab: Tab = .install) {
        self.profile = profile; self.dismiss = dismiss; self.run = run; self.restarting = restarting
        _loader = StateObject(wrappedValue: InstallScriptLoader(file: profile.installScriptFile, preset: preset))
        _tab = State(initialValue: tab)
    }

    private var machine: String { profile.name.replacingOccurrences(of: " terminal", with: "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(tab == .install ? "Install script" : "Cloud folders").font(.title2.bold())
                Spacer()
                Picker("", selection: $tab) {
                    Text("Install").tag(Tab.install)
                    Text("Cloud").tag(Tab.cloud)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            if tab == .install { installTab } else {
                CloudTab(machineID: profile.machineID ?? profile.id, machine: machine, dismiss: dismiss, restarting: restarting)
            }
        }
        .padding(20)
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if loader.state == .loading { await loader.load() } }
    }

    @ViewBuilder private var installTab: some View {
            Text("Runs in \(machine)'s terminal, as its user. Choose what to install, or read and change the script itself.")
                .font(.callout).foregroundStyle(.secondary)
            let options = InstallScript.options(in: loader.text)
            if !options.isEmpty {
                HStack(spacing: 18) {
                    ForEach(options) { o in
                        Toggle(o.label, isOn: Binding(get: { o.on }, set: { loader.text = InstallScript.setting(o.name, to: $0, in: loader.text) }))
                            .toggleStyle(.checkbox)
                    }
                    Spacer(minLength: 0)
                }
                .disabled(uploading)
            }
            ZStack {
                TextEditor(text: $loader.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .padding(6)
                    .disabled(uploading || loader.state == .loading)
                if loader.state == .loading { ProgressView("Loading \(loader.file)…").controlSize(.small) }
            }
            .frame(height: 360)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            if let problem { Banner(text: problem, kind: .error) }
            HStack(spacing: 10) {
                source
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                if case .failed = loader.state {
                    Button("Try Again") { Task { await loader.load() } }.keyboardShortcut(.defaultAction)
                } else {
                    if uploading { ProgressView().controlSize(.small) }
                    Button("Run in Terminal") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(uploading || loader.state == .loading || loader.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
    }

    /// Where the text came from, bottom left.
    @ViewBuilder private var source: some View {
        switch loader.state {
        case .loaded(fromGitHub: true):
            Link(destination: InstallScript.url(loader.file)) { Label("From github.com/adminmylinux/mylinux", systemImage: "globe") }
                .font(.caption).foregroundStyle(.secondary)
        case .loaded(fromGitHub: false):
            Banner(text: "GitHub couldn't be reached; this is the copy built into the launcher.", kind: .warning)
        case .failed(let why):
            Banner(text: why, kind: .error)
        case .loading:
            EmptyView()
        }
    }

    private func start() {
        problem = nil; uploading = true
        Task {
            let failure = await InstallScriptUpload.upload(loader.text, file: loader.file, profile: profile)
            uploading = false
            if let failure { problem = failure; return }
            run(InstallScript.command(file: loader.file, script: loader.text)); dismiss()
        }
    }
}

/// The Cloud tab: a checkbox for each cloud folder the Mac has. Ticked ones are shared into the machine as ~/<name>,
/// beside ~/Mac; a share is attached when the machine starts, so a change restarts a running machine.
struct CloudTab: View {
    let machineID: UUID
    let machine: String
    let dismiss: () -> Void
    var restarting: () -> Void = {}
    @ObservedObject private var store = ProfileStore.shared
    @State private var picked: Set<String> = []
    @State private var loaded = false

    private var saved: Profile? { store.profiles.first { $0.id == machineID } }
    private var running: Bool { RunManager.shared.runner(for: machineID).isActive }
    private var changed: Bool { Set(saved?.cloudFolders ?? []) != picked }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Mac's cloud folders inside \(machine), beside ~/Mac. The Mac's own apps keep them in sync, so there is nothing to sign in to inside; what the machine writes there syncs too.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(CloudFolder.allCases.enumerated()), id: \.element) { i, f in
                    if i > 0 { Divider() }
                    row(f)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            Text(running ? "Folders are attached when the machine starts: saving a change restarts \(machine), and its terminals reconnect."
                         : "Folders are attached when the machine starts, so a change takes effect at the next Start.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(running ? "Save and Restart" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!changed || saved == nil)
            }
        }
        .frame(height: 458)
        .onAppear { if !loaded { picked = Set(saved?.cloudFolders ?? []); loaded = true } }
    }

    private func row(_ f: CloudFolder) -> some View {
        let path = f.macPath()
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { picked.contains(f.rawValue) }, set: { on in if on { picked.insert(f.rawValue) } else { picked.remove(f.rawValue) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title).fontWeight(.semibold)
                    Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not on this Mac")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(path == nil && !picked.contains(f.rawValue))
            Spacer()
            Text("~/\(f.guestName)").font(.callout.monospaced()).foregroundStyle(path == nil ? .tertiary : .secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func save() {
        guard var p = saved else { return }
        p.cloudFolders = CloudFolder.allCases.map(\.rawValue).filter { picked.contains($0) }
        store.update(p)
        let r = RunManager.shared.runner(for: machineID)
        if MachineApp.active {
            // in the machine's own app: the launcher saves and restarts; this window shows the seconds
            MachineLink.request(["action": "cloudFolders", "folders": p.cloudFolders, "restart": r.isActive])
            if r.isActive { r.mirrorRestartAsked(); restarting() } else { dismiss() }
            return
        }
        if r.isActive { r.restart(p); restarting() } else { dismiss() }
    }
}
