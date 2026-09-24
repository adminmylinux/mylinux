import Foundation

/// What "Install Agents…" in a machine's terminal window puts into the guest: coding agents with an alias each, and
/// the packages they need. The choice becomes one bash script (`script`), run over the machine's SSH connection.
struct AgentInstallOptions: Equatable {
    var claude = true
    var claudeAlias = true
    var claudeAliasName = "cc"
    var claudeAliasCommand = "claude update && claude --dangerously-skip-permissions"
    var codex = false
    var codexAlias = true
    var codexAliasName = "cx"
    var codexAliasCommand = "codex --full-auto"
    var basics = true            // git, tmux (curl and certificates always)

    static let claudeInstaller = "https://claude.ai/install.sh"
    static let codexDownload = "https://github.com/openai/codex/releases/latest/download/codex-aarch64-unknown-linux-musl.tar.gz"

    /// A shell alias name: letters, digits and underscores, not starting with a digit.
    static func validAliasName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }
    /// Text inside single quotes for the shell.
    static func singleQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var problems: [String] {
        var p: [String] = []
        if !claude && !codex && !basics { p.append("Nothing is selected.") }
        if claude && claudeAlias && !AgentInstallOptions.validAliasName(claudeAliasName) { p.append("The Claude alias needs a plain name (letters, digits, _).") }
        if codex && codexAlias && !AgentInstallOptions.validAliasName(codexAliasName) { p.append("The Codex alias needs a plain name (letters, digits, _).") }
        if claude && claudeAlias && claudeAliasCommand.trimmingCharacters(in: .whitespaces).isEmpty { p.append("The Claude alias needs a command.") }
        if codex && codexAlias && codexAliasCommand.trimmingCharacters(in: .whitespaces).isEmpty { p.append("The Codex alias needs a command.") }
        return p
    }

    /// The script: packages first, then each agent into ~/.local/bin, then the aliases in one marked block of
    /// ~/.bashrc (replaced on a rerun, so nothing piles up), then each installed agent reports its version.
    var script: String {
        var s = """
        #!/bin/bash
        # myLinux: install coding agents (made by the launcher from the choices in the Install Agents dialog)
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        cd "$HOME"
        mkdir -p "$HOME/.local/bin"
        echo "== packages"
        sudo -n apt-get update -q
        sudo -n apt-get install -y -q curl ca-certificates\(basics ? " git tmux" : "")

        """
        if claude {
            s += """
            echo "== Claude Code"
            curl -fsSL \(AgentInstallOptions.claudeInstaller) | bash

            """
        }
        if codex {
            s += """
            echo "== Codex"
            curl -fsSL -o /tmp/codex.tar.gz \(AgentInstallOptions.codexDownload)
            tar -xzf /tmp/codex.tar.gz -C /tmp codex-aarch64-unknown-linux-musl
            install -m 0755 /tmp/codex-aarch64-unknown-linux-musl "$HOME/.local/bin/codex"
            rm -f /tmp/codex.tar.gz /tmp/codex-aarch64-unknown-linux-musl

            """
        }
        var aliases: [String] = []
        if claude && claudeAlias { aliases.append("alias \(claudeAliasName)=\(AgentInstallOptions.singleQuoted(claudeAliasCommand))") }
        if codex && codexAlias { aliases.append("alias \(codexAliasName)=\(AgentInstallOptions.singleQuoted(codexAliasCommand))") }
        // a quoted heredoc: the block lands in .bashrc exactly as written here
        s += """
        echo "== shell setup"
        touch "$HOME/.bashrc"
        sed -i '/^# >>> myLinux agents >>>$/,/^# <<< myLinux agents <<<$/d' "$HOME/.bashrc"
        cat >> "$HOME/.bashrc" <<'MYLINUX_AGENTS'
        # >>> myLinux agents >>>
        case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
        \(aliases.joined(separator: "\n"))
        # <<< myLinux agents <<<
        MYLINUX_AGENTS

        """
        s += "echo \"== done\"\n"
        if claude { s += "\"$HOME/.local/bin/claude\" --version\n" }
        if codex { s += "\"$HOME/.local/bin/codex\" --version\n" }
        return s
    }
}

/// Runs the script in the guest over ssh (the same arguments as the terminal, so the machine's key and known_hosts
/// are used) and publishes its output.
final class AgentInstallRunner: ObservableObject {
    enum State: Equatable { case idle, running, done, failed(String) }
    @Published private(set) var state = State.idle
    @Published private(set) var output = ""
    private var process: Process?

    func run(_ options: AgentInstallOptions, profile: RemoteProfile) {
        guard state != .running else { return }
        state = .running; output = ""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = SshTerminal.arguments(for: profile) + ["bash", "-s"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.toolPath
        proc.environment = env
        let input = Pipe(), out = Pipe()
        proc.standardInput = input; proc.standardOutput = out; proc.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { guard let self else { return }; self.output = String((self.output + text).suffix(60_000)) }
        }
        proc.terminationHandler = { [weak self] pr in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.state = pr.terminationStatus == 0 ? .done : .failed("The install ended with status \(pr.terminationStatus). See the output above.")
            }
        }
        do {
            try proc.run(); process = proc
            input.fileHandleForWriting.write(Data(options.script.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            state = .failed("Could not start ssh: \(error.localizedDescription)")
        }
    }

    func cancel() { process?.terminate() }
}
