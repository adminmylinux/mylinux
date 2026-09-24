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
        VStack(alignment: .leading, spacing: 12) {
            Text("Install agents in \(profile.name.replacingOccurrences(of: " terminal", with: ""))").font(.title3.bold())
            Form {
                Section {
                    Toggle("Claude Code", isOn: $options.claude)
                    Text("Anthropic's native installer, into ~/.local/bin. Sign in with `claude` the first time.").font(.caption).foregroundStyle(.secondary)
                    if options.claude {
                        Toggle("Alias", isOn: $options.claudeAlias)
                        if options.claudeAlias { aliasRow(name: $options.claudeAliasName, command: $options.claudeAliasCommand) }
                    }
                }
                Section {
                    Toggle("Codex (OpenAI)", isOn: $options.codex)
                    Text("The prebuilt Linux binary from the latest release, into ~/.local/bin. Sign in with `codex` the first time.").font(.caption).foregroundStyle(.secondary)
                    if options.codex {
                        Toggle("Alias", isOn: $options.codexAlias)
                        if options.codexAlias { aliasRow(name: $options.codexAliasName, command: $options.codexAliasCommand) }
                    }
                }
                Section {
                    Toggle("Basics: git and tmux", isOn: $options.basics)
                    Text("curl and certificates are installed either way. Everything runs as the machine's user through sudo where needed.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(runner.state == .running)
            .frame(minHeight: 300)
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
        }
        .padding(20)
        .frame(width: 560)
    }

    private func aliasRow(name: Binding<String>, command: Binding<String>) -> some View {
        HStack {
            TextField("name", text: name).frame(width: 60)
            Text("=").foregroundStyle(.secondary)
            TextField("command", text: command).font(.body.monospaced())
        }
    }
}
