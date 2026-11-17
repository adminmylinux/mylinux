import Foundation
import Security

/// What a new machine gets when the person does not say (Settings › AI › Defaults, and Ask AI… asks for them the first
/// time a request needs them). The password is in the Keychain; the rest in the launcher's settings. An empty field is
/// "as on this Mac": the launcher's command takes this Mac's user name, keyboard and time zone then.
struct MachineDefaults: Codable, Equatable {
    var user = ""
    /// Omarchy's name for the keyboard ("Norwegian", OmarchyUnattended.layouts)
    var keyboard = ""
    var timezone = ""
    var fullName = ""
    var email = ""

    static let key = "ai.defaults"
    /// nil: none stored yet.
    static var stored: MachineDefaults? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(MachineDefaults.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
    }
    /// This Mac's: what the new-machine dialog suggests (OmarchyUnattended.suggested).
    static var suggested: MachineDefaults {
        let a = OmarchyUnattended.suggested(machine: "omarchy")
        return MachineDefaults(user: a.user, keyboard: a.keyboard, timezone: a.timezone)
    }

    // the password: a generic Keychain item of the launcher's own
    static let service = "myLinux Defaults", account = "password"
    static var password: String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    @discardableResult
    static func setPassword(_ pw: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !pw.isEmpty else { return true }
        var add = q; add[kSecValueData as String] = Data(pw.utf8); add[kSecAttrLabel as String] = "myLinux Launcher: a new machine's password"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Ask AI…: the person says what they want of the launcher ("Create omarchy machine 8/32 with username viktor and the
/// rest as default"), the AI (AI.swift: their Claude Code or Codex) turns it into the launcher's own commands, the ones
/// `mylinux` takes (CLI.swift), the launcher fills in the stored defaults (the password never goes to the AI), shows
/// the commands, and carries them out when the person says Run, as the command line would (CLIService.handle).
enum AskAI {
    struct Plan: Decodable, Equatable {
        var say: String?
        var commands: [[String]]?
    }
    /// What Ask AI may do: the machines' own commands. Never erase, ssh (a command inside a machine), skill or anything else.
    static let allowed: Set<String> = ["kinds", "list", "status", "create", "start", "stop", "restart", "delete", "claude", "codex"]

    /// The prompt: the commands, the rules, what is stored (never the password itself) and the machines there are now.
    static func system(machines: [[String: Any]], defaults: MachineDefaults?, hasPassword: Bool) -> String {
        let list = machines.map { m in
            ["name", "kind", "state", "memoryGB", "diskGB"].compactMap { k in m[k].map { "\(k): \($0)" } }.joined(separator: ", ")
        }
        let stored: String
        if let d = defaults {
            stored = "user \(d.user.isEmpty ? "(this Mac's)" : d.user), password \(hasPassword ? "stored" : "not stored"), keyboard \(d.keyboard.isEmpty ? "(this Mac's)" : d.keyboard), time zone \(d.timezone.isEmpty ? "(this Mac's)" : d.timezone)"
        } else {
            stored = "none stored yet (the launcher asks the person for them when a command needs them)"
        }
        return """
            You turn what a person asks of myLinux Launcher, a Mac app that runs Linux and Windows virtual machines, into the \
            launcher's own commands: those its `mylinux` command line takes. Reply with ONE JSON object only:
            {"say": "...", "commands": [["create", "omarchy", "--name", "Omarchy", "--memory", "8", "--disk", "32", "--user", "viktor"]]}
            - say: one or two short sentences in the person's language, plain text: what the commands do, or the answer to a question, \
            or why it cannot be done.
            - commands: each a list of words as typed after `mylinux`, in order; [] when there is nothing to do.

            The commands (use only kinds, list, status, create, start, stop, restart, delete, claude and codex: never erase, ssh or skill):
            \(CLI.usage)

            Rules:
            - "8/32" with a machine is 8 GB of memory and a 32 GB disk; "8 GB" alone is the memory.
            - A new omarchy machine always gets --unattended. The launcher fills its account from the person's stored defaults \
            (user name, password, keyboard, time zone, full name, e-mail): write only what the person says, e.g. "with username viktor" is \
            --user viktor, and "the rest as default" adds nothing. Never write --password unless the person typed the password in their request.
            - A new windows machine gets --unattended --accept-microsoft-license only when the person says they accept Microsoft's licence \
            terms; otherwise create it without them.
            - delete only when the person clearly asks for it, then with --yes, and --stop when the machine is running.
            - Name machines as in the list below (the person's words may differ in case or a little). A new machine's --name is what the \
            person calls it; leave --name out when they give none.
            - No --wait and no --timeout: the launcher shows the machines' progress itself.
            - A question about the machines is answered in say, from the list below, with no commands.

            The person's stored defaults: \(stored).
            The machines now: \(list.isEmpty ? "none" : "\n" + list.map { "- " + $0 }.joined(separator: "\n"))
            """
    }

    /// The commands as they may run: only the allowed ones, without --wait and --timeout (what follows them goes too).
    static func checked(_ plan: Plan) -> (commands: [[String]], refused: [String]) {
        var ok: [[String]] = [], refused: [String] = []
        for c in plan.commands ?? [] {
            var argv = c.first == "mylinux" ? Array(c.dropFirst()) : c
            guard let first = argv.first, allowed.contains(first) else { refused.append(c.joined(separator: " ")); continue }
            var i = 0
            while i < argv.count {
                if argv[i] == "--wait" { argv.remove(at: i) }
                else if argv[i] == "--timeout" { argv.removeSubrange(i..<min(i + 2, argv.count)) }
                else if argv[i].hasPrefix("--timeout=") { argv.remove(at: i) }
                else { i += 1 }
            }
            ok.append(argv)
        }
        return (ok, refused)
    }

    /// A create's account filled in from the stored defaults: an omarchy gets --unattended, and the user name, password,
    /// keyboard, time zone, full name and e-mail it does not name; a windows that is unattended its user name and password.
    /// `missing`: what the command needs and is not stored ("defaults" when nothing is stored yet, "password").
    static func filled(_ argv: [String], defaults: MachineDefaults?, password: String?) -> (argv: [String], missing: [String]) {
        guard argv.first == "create", argv.count > 1, let kind = CLI.kind(argv[1]), kind == .omarchy || (kind == .windows && argv.contains("--unattended")) else {
            return (argv, [])
        }
        var a = argv, missing: [String] = []
        func has(_ flag: String) -> Bool { a.contains("--\(flag)") || a.contains { $0.hasPrefix("--\(flag)=") } }
        if kind == .omarchy, !has("unattended") { a.append("--unattended") }
        if defaults == nil { missing.append("defaults") }
        let d = defaults ?? MachineDefaults()
        if !has("password") {
            if let pw = password { a += ["--password", pw] } else if kind == .omarchy { missing.append("password") }
        }
        if !has("user"), !d.user.isEmpty { a += ["--user", d.user] }
        if kind == .omarchy {
            if !has("keyboard"), !d.keyboard.isEmpty { a += ["--keyboard", d.keyboard] }
            if !has("timezone"), !d.timezone.isEmpty { a += ["--timezone", d.timezone] }
            if !has("full-name"), !d.fullName.isEmpty { a += ["--full-name", d.fullName] }
            if !has("email"), !d.email.isEmpty { a += ["--email", d.email] }
        }
        return (a, missing)
    }

    /// A command as the person sees it: the password as dots, words with spaces quoted.
    static func shown(_ argv: [String]) -> String {
        var out = ["mylinux"], hide = false
        for w in argv {
            if hide { out.append("••••••"); hide = false; continue }
            if w == "--password" { hide = true }
            if w.hasPrefix("--password=") { out.append("--password=••••••"); continue }
            out.append(w.contains(" ") || w.isEmpty ? "\"\(w)\"" : w)
        }
        return out.joined(separator: " ")
    }

    /// One line for a command's answer.
    static func outcome(_ reply: CLI.Reply) -> (ok: Bool, text: String) {
        let j = reply.json
        if j["ok"] as? Bool == false { return (false, j["error"] as? String ?? "failed") }
        if let m = j["machine"] as? [String: Any], let name = m["name"] as? String {
            let job = (m["job"] as? [String: Any])?["phase"] as? String
            return (true, "\(name): \(job ?? m["state"] as? String ?? "done")" + (j["created"] as? Bool == true ? " (created)" : ""))
        }
        if let gone = j["deleted"] as? String { return (true, "\(gone): in the Trash") }
        if let ms = j["machines"] as? [[String: Any]] { return (true, ms.map { "\($0["name"] ?? "?"): \($0["state"] ?? "?")" }.joined(separator: ", ")) }
        return (true, "done")
    }
}
