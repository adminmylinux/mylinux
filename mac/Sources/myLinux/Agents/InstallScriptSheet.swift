import SwiftUI
import AppKit

/// The Install Script dialog: the machine's install script (debian_install.sh, alpine_install.sh) as loaded from GitHub, a checkbox for each of its options, and the
/// text itself to read or change. Run copies the text into the machine and runs it in the terminal, in view.
struct InstallScriptSheet: View {
    let profile: RemoteProfile
    let dismiss: () -> Void
    /// Called once the script is in the machine, with the command the window types into the terminal.
    let run: (String) -> Void
    @StateObject private var loader: InstallScriptLoader
    @State private var uploading = false
    @State private var problem: String?

    /// `preset`, for pictures of the dialog: start with this text instead of loading it.
    init(profile: RemoteProfile, dismiss: @escaping () -> Void, run: @escaping (String) -> Void, preset: String? = nil) {
        self.profile = profile; self.dismiss = dismiss; self.run = run
        _loader = StateObject(wrappedValue: InstallScriptLoader(file: profile.installScriptFile, preset: preset))
    }

    private var machine: String { profile.name.replacingOccurrences(of: " terminal", with: "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install script").font(.title2.bold())
                Text("Runs in \(machine)'s terminal, as its user. Choose what to install, or read and change the script itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
        .padding(20)
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if loader.state == .loading { await loader.load() } }
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
