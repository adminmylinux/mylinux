import SwiftUI
import AppKit

/// The Install Agents dialog: which agents, with which alias, then the script's output while it runs.
struct AgentsSheet: View {
    let profile: RemoteProfile
    let dismiss: () -> Void
    /// Called once the install has succeeded (the window types `source ~/.bashrc` into the terminal).
    let finished: () -> Void
    @State private var options = AgentInstallOptions()
    @StateObject private var runner = AgentInstallRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install agents").font(.title2.bold())
                Text("Into \(profile.name.replacingOccurrences(of: " terminal", with: "")), as its user, over the machine's SSH connection.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
            Form {
                agentSection(title: "Claude Code", on: $options.claude, alias: $options.claudeAlias,
                             name: $options.claudeAliasName, command: $options.claudeAliasCommand,
                             note: "Anthropic's native installer, into ~/.local/bin. Sign in with claude the first time.")
                agentSection(title: "Codex", subtitle: "OpenAI", on: $options.codex, alias: $options.codexAlias,
                             name: $options.codexAliasName, command: $options.codexAliasCommand,
                             note: "The prebuilt Linux binary from the latest release, into ~/.local/bin. Sign in with codex the first time.")
                Section {
                    Toggle(isOn: $options.basics) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Basics")
                            Text("git and tmux. curl and certificates come either way.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(runner.state == .running)
            VStack(alignment: .leading, spacing: 10) {
            if let first = options.problems.first, runner.state == .idle { Banner(text: first, kind: .warning) }
            if runner.state != .idle {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(runner.output.isEmpty ? "Connecting…" : runner.output)
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: runner.output) { _, _ in proxy.scrollTo("end") }
                }
            }
            if case .failed(let why) = runner.state { Banner(text: why, kind: .error) }
            if runner.state == .done { Banner(text: "Installed. The terminal picks up the aliases now; new shells have them too.", kind: .info) }
            }
            .padding(.horizontal, 20)
            HStack {
                Spacer()
                switch runner.state {
                case .idle:
                    Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                    Button("Install") { runner.run(options, profile: profile) }.keyboardShortcut(.defaultAction).disabled(!options.problems.isEmpty)
                case .running:
                    ProgressView().controlSize(.small)
                    Button("Stop") { runner.cancel() }
                case .done:
                    Button("Done") { finished(); dismiss() }.keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                    Button("Try Again") { runner.run(options, profile: profile) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// One agent: the switch with its explanation, and under it the alias switch with the name and command fields.
    private func agentSection(title: String, subtitle: String? = nil, on: Binding<Bool>, alias: Binding<Bool>,
                              name: Binding<String>, command: Binding<String>, note: String) -> some View {
        Section {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                        if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                    }
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            if on.wrappedValue {
                Toggle("Alias", isOn: alias)
                if alias.wrappedValue {
                    HStack(spacing: 6) {
                        TextField("", text: name, prompt: Text("name")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 64)
                        Text("=").foregroundStyle(.secondary)
                        TextField("", text: command, prompt: Text("command")).labelsHidden().textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
