import AppKit

/// "Sign Codex in as on the Mac" (server-apps/codex-login.sh: a snippet, and an entry in myLinux Apps). Codex has no
/// token to paste, as `claude setup-token` gives Claude Code; what OpenAI documents for a machine without a browser
/// is a copy of ~/.codex/auth.json from a computer that is signed in. Nothing inside a machine can read the Mac's
/// files, so the machine asks through its share folder: the script writes .mylinux/codex-login-request there, the
/// launcher's watcher (RunManager) takes it and asks here on the Mac, and on yes the login file goes into the share
/// as .mylinux/codex-auth.json, which the script moves into ~/.codex inside. A no, or no login on this Mac, is
/// .mylinux/codex-login-declined with the reason. A login nobody collected is removed from the share after a minute.
enum CodexLogin {
    static func folder(_ share: String) -> URL { URL(fileURLWithPath: share).appendingPathComponent(".mylinux", isDirectory: true) }
    static func requestFile(_ share: String) -> URL { folder(share).appendingPathComponent("codex-login-request") }
    static func loginFile(_ share: String) -> URL { folder(share).appendingPathComponent("codex-auth.json") }
    static func declinedFile(_ share: String) -> URL { folder(share).appendingPathComponent("codex-login-declined") }

    /// Codex's login on this Mac, when it keeps it in a file (cli_auth_credentials_store "file", or "auto" with no keychain).
    static var macLogin: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json") }
    /// The script inside gives up after three minutes: a request older than that is only cleared away.
    static let requestLifetime: TimeInterval = 170
    /// How long a delivered login may wait in the share for the script to collect it.
    static let loginLifetime: TimeInterval = 60

    /// The request, taken, and how old it was. Removing the file is the taking: of the launcher and a machine's own
    /// app, which both watch, exactly one gets it.
    static func take(_ share: String, now: Date = Date()) -> TimeInterval? {
        let url = requestFile(share)
        let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return nil }
        return now.timeIntervalSince(written ?? now)
    }

    /// A login file as Codex writes it: a JSON object. Nil when it is missing, empty or something else.
    static func login(at url: URL = macLogin) -> Data? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }

    /// The login into the share, readable by its owner only (the share shows the Mac user's files as the machine's user).
    @discardableResult static func deliver(_ data: Data, to share: String) -> Bool {
        let url = loginFile(share)
        do {
            try FileManager.default.createDirectory(at: folder(share), withIntermediateDirectories: true)
            let tmp = folder(share).appendingPathComponent(".codex-auth.\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return true
        } catch { return false }
    }

    static func decline(_ share: String, _ reason: String) {
        try? FileManager.default.createDirectory(at: folder(share), withIntermediateDirectories: true)
        try? Data((reason + "\n").utf8).write(to: declinedFile(share), options: .atomic)
    }

    /// A delivered login the script never collected (it was interrupted, or the answer came after it gave up).
    static func sweep(_ share: String, now: Date = Date()) {
        let url = loginFile(share)
        guard let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
              now.timeIntervalSince(written) > loginLifetime else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The watcher saw a request in this machine's share: ask, and answer it. On the main thread.
    static func answer(_ machine: Profile) {
        let share = machine.shareDir
        guard let age = take(share), age < requestLifetime else { return }
        guard let data = login() else {
            decline(share, "Codex on your Mac has no login file (~/.codex/auth.json). Sign in there first (codex login); if it keeps its login in the Keychain, set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml and sign in again.")
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Sign Codex in inside “\(machine.name)” with this Mac's login?"
        alert.informativeText = "“\(machine.name)” asked for it (Sign Codex in as on the Mac, in Snippets… or Apps…). The launcher then copies ~/.codex/auth.json, your Codex login, into the machine: Codex there runs as you, on your ChatGPT plan, and whatever runs in that machine can read the login."
        alert.addButton(withTitle: "Copy Login")
        alert.addButton(withTitle: "Don't Copy")
        if alert.runModal() == .alertFirstButtonReturn {
            if deliver(data, to: share) {
                DispatchQueue.main.asyncAfter(deadline: .now() + loginLifetime + 1) { sweep(share) }
            } else {
                decline(share, "the launcher could not write into the share folder.")
            }
        } else {
            decline(share, "you chose Don't Copy on the Mac.")
        }
    }
}
