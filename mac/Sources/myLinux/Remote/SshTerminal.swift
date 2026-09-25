import AppKit
import SwiftTerm

/// An SSH terminal: SwiftTerm's local-process view running the Mac's ssh on a pty. Keys come from ~/.ssh and the
/// agent; a saved password is handed to ssh through SSH_ASKPASS (a helper that reads it from the Keychain, so it
/// never sits in a file or in an environment variable); a tmux session name attaches with `tmux new-session -A`.
final class SshTerminal: LocalProcessTerminalView {
    let profile: RemoteProfile
    var onExit: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    /// A link the user activated (⌘-click); when nil, links open in the default browser.
    var onOpenLink: ((URL) -> Void)?
    private let bridge = Bridge()

    /// SwiftTerm's view implements its own delegate methods, so the callbacks go through this helper
    private final class Bridge: LocalProcessTerminalViewDelegate {
        weak var owner: SshTerminal?
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) { owner?.onTitle?(title) }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) { owner?.onExit?(exitCode) }
    }

    init(profile: RemoteProfile) {
        self.profile = profile
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        bridge.owner = self
        processDelegate = bridge
        nativeBackgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        nativeForegroundColor = NSColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// the askpass helper: `security find-generic-password -w` for this profile's Keychain item
    static var askpassScript: URL {
        let url = Paths.support.appendingPathComponent("ssh-askpass.sh")
        let script = "#!/bin/sh\n# myLinux Launcher: ssh asks here for the password of the machine named in SSH_ASKPASS_ACCOUNT\nexec /usr/bin/security find-generic-password -w -s \"\(RemoteSecrets.service)\" -a \"$SSH_ASKPASS_ACCOUNT\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    /// ssh's arguments up to the destination: port, host-key policy, the profile's options and key.
    static func arguments(for profile: RemoteProfile) -> [String] {
        var args = ["-p", String(profile.port), "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=30"]
        for o in profile.sshOptions { args += ["-o", o] }
        if !profile.keyFile.isEmpty { args += ["-i", (profile.keyFile as NSString).expandingTildeInPath] }
        args.append(profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)")
        return args
    }

    /// Types text into the session, as if at the keyboard.
    func type(_ text: String) { send(source: self, data: ArraySlice(Array(text.utf8))) }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let handler = onOpenLink, let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") { handler(url); return }
        super.requestOpenLink(source: source, link: link, params: params)
    }

    /// The last http(s) URL on screen or in the scrollback. A long URL wraps at the terminal's width; a row that is
    /// exactly that wide continues on the next row, so those are joined again before the search.
    func lastURL() -> URL? {
        let terminal = getTerminal()
        let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        return SshTerminal.lastURL(in: text, cols: terminal.cols)
    }
    static func lastURL(in text: String, cols: Int) -> URL? {
        var joined = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            joined += line
            if line.count < cols { joined += "\n" }
        }
        guard let re = try? NSRegularExpression(pattern: "https?://[^\\s'\"<>]+") else { return nil }
        let text = joined
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for m in matches.reversed() {
            guard let r = Range(m.range, in: text) else { continue }
            var s = String(text[r])
            while let last = s.last, ".,;:)]}".contains(last) { s.removeLast() }
            if let u = URL(string: s) { return u }
        }
        return nil
    }

    func start() {
        var args = SshTerminal.arguments(for: profile)
        let tmux = profile.tmux.trimmingCharacters(in: .whitespaces)
        if !tmux.isEmpty { args.insert("-t", at: args.count - 1); args += ["tmux", "new-session", "-A", "-s", tmux] }
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("COLORTERM=truecolor")
        env.append("HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        if let path = ProcessInfo.processInfo.environment["PATH"] { env.append("PATH=\(path)") }
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { env.append("SSH_AUTH_SOCK=\(agent)") }
        if profile.hasPassword {
            env.append("SSH_ASKPASS=\(SshTerminal.askpassScript.path)")
            env.append("SSH_ASKPASS_REQUIRE=prefer")           // the helper first; a failing helper falls back to the terminal prompt
            env.append("SSH_ASKPASS_ACCOUNT=\(RemoteSecrets.account(profile))")
            env.append("DISPLAY=myLinux")                       // ssh insists on a display before it uses askpass
        }
        // MYLINUX_LOCAL_SHELL=1: a local shell instead of ssh, for looking at the window without a machine
        if ProcessInfo.processInfo.environment["MYLINUX_LOCAL_SHELL"] == "1" {
            startProcess(executable: "/bin/sh", args: ["-c", "printf 'Xabcdefghij first column check\\n0123456789 second line\\n'; exec /bin/sh -i"], environment: env, currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }
        startProcess(executable: "/usr/bin/ssh", args: args, environment: env, currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

}
