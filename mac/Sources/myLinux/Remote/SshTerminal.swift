import Foundation

/// How the launcher runs the Mac's ssh for a machine: the arguments, and the password helper. The terminals
/// (GhosttySshTerminal) and the background connections (tunnels, stats, install scripts) all use these. Keys come
/// from ~/.ssh and the agent; a saved password is handed to ssh through SSH_ASKPASS (a helper that reads it from the
/// Keychain, so it never sits in a file or in an environment variable).
enum SshTerminal {
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

    /// The last http(s) URL in a terminal's text. A long URL wraps at the terminal's width; a row that is exactly that
    /// wide continues on the next row, so those are joined again before the search.
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
}
