import Foundation

/// "Install Claude Code" and "Install Codex" in the dialog of a new Omarchy or Windows machine (FirstStartSheet): what
/// was ticked there is carried out by the launcher once the machine is up for the first time, with nobody opening
/// Claude Install… or Codex Install…. The terminal versions: Claude Code with its status line (in Windows also Git,
/// which it works through), and Codex with the alias cx; not the desktop apps.
///
/// The wish waits in the machine's folder (`first-start.tools`, for the Mac user alone: it can hold the Claude token
/// that was typed into the dialog) from Create to the first time the machine's helper answers, which is when its
/// desktop is there (an Omarchy that set itself up, a Windows that installed itself and restarted, or either after a
/// person answered its questions). Then the wizards' own models do the work (as `mylinux claude` and `mylinux codex`
/// drive them, AgentCommands), the file is removed whatever came of it, and the machine's page says how it went.
@MainActor final class FirstStartTools: ObservableObject {
    static let shared = FirstStartTools()

    struct Wish: Codable, Equatable {
        var claude = false
        /// A token from `claude setup-token`, as typed into the dialog; empty: Claude Code is installed and the user signs in inside.
        var token = ""
        /// What the subscription is called (the status line shows it).
        var account = ""
        var codex = false
        /// Codex is signed in with this Mac's own login (a copy of ~/.codex/auth.json), as the wizard offers.
        var codexLogin = false
        var isEmpty: Bool { !claude && !codex }
    }
    /// Where a machine's wish stands: waiting for the machine, at work on something, or how it ended.
    enum Phase: Equatable { case waiting, working(String), done([String]), failed([String]) }
    @Published private(set) var phases: [UUID: Phase] = [:]
    private var busy: Set<UUID> = []
    private var nextTry: [UUID: Date] = [:]

    nonisolated static func file(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("first-start.tools") }
    nonisolated static func kept(_ machineFolder: URL) -> Wish? {
        (try? Data(contentsOf: file(machineFolder))).flatMap { try? JSONDecoder().decode(Wish.self, from: $0) }
    }
    /// Keeps the wish for the machine's first start, for the Mac user alone (an empty wish is none): nil, or what went wrong.
    nonisolated static func keep(_ wish: Wish, machineFolder: URL) -> String? {
        guard !wish.isEmpty else { forget(machineFolder); return nil }
        guard let data = try? JSONEncoder().encode(wish) else { return "could not write what to install" }
        let fm = FileManager.default, url = file(machineFolder), tmp = machineFolder.appendingPathComponent(".first-start.tools.tmp")
        do {
            try fm.createDirectory(at: machineFolder, withIntermediateDirectories: true)
            try? fm.removeItem(at: tmp)
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return "could not write \(url.path)" }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
            return nil
        } catch { return "could not keep what to install: \(error.localizedDescription)" }
    }
    nonisolated static func forget(_ machineFolder: URL) { try? FileManager.default.removeItem(at: file(machineFolder)) }

    /// A name for a subscription from the account's name: one word of letters, digits, . _ @ - (as the wizard asks for one).
    nonisolated static func accountName(_ user: String) -> String {
        let word = String(user.unicodeScalars.map { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._@-".unicodeScalars.contains($0) ? Character($0) : "-" })
        let trimmed = String(word.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        return trimmed.isEmpty ? "claude" : trimmed
    }
    /// What is wrong with a token typed into the dialog, or nil (empty is no token: the user signs in inside).
    nonisolated static func tokenProblem(_ token: String) -> String? {
        let clean = token.components(separatedBy: .whitespacesAndNewlines).joined()
        if clean.isEmpty { return nil }
        return clean.range(of: "^[A-Za-z0-9_-]{20,}$", options: .regularExpression) == nil ? "That does not look like a token from claude setup-token (sk-ant-oat01-…)." : nil
    }

    /// The wish is not wanted after all (the page's button), while nothing has been done about it.
    func cancel(_ p: Profile) {
        guard !busy.contains(p.id) else { return }
        Self.forget(p.machineFolder); phases[p.id] = nil; nextTry[p.id] = nil
    }

    /// RunManager's tick, for a running Omarchy or Windows: a wish is carried out when the machine's helper answers.
    func follow(_ p: Profile, runner: Runner, now: Date = Date()) {
        guard FirstStartSheet.asks(p.kind), !busy.contains(p.id) else { return }
        guard let wish = Self.kept(p.machineFolder) else {
            if case .waiting = phases[p.id] { phases[p.id] = nil }       // forgotten meanwhile
            return
        }
        guard runner.state == .running || runner.state == .inUseElsewhere else { return }
        // not while it is still setting itself up: an Omarchy before its desktop, a Windows before it is installed and restarted
        if p.kind == .omarchy ? OmarchyUnattended.stage(p) == .settingUp : (!p.windowsInstalled || WindowsUnattended.inProgress(p)) {
            if phases[p.id] != .waiting { phases[p.id] = .waiting }
            return
        }
        if let t = nextTry[p.id], now < t { return }
        busy.insert(p.id)
        Task { @MainActor in
            await carryOut(wish, p)
            busy.remove(p.id)
        }
    }

    private func settle(_ still: @MainActor () -> Bool) async {
        while still() { try? await Task.sleep(nanoseconds: 400_000_000) }
    }
    private static func failure(_ steps: [ClaudeStep]) -> String {
        guard let s = steps.first(where: { $0.state == "failed" }) else { return "it did not end well" }
        return s.detail.isEmpty ? "\(s.title): failed" : "\(s.title): \(s.detail.split(separator: "\n").first.map(String.init) ?? s.detail)"
    }

    private func carryOut(_ wish: Wish, _ p: Profile) async {
        // the helper inside answers when somebody is signed in to the desktop: until then, asked again in a while
        let look = ClaudeInstallModel(machine: p)
        look.answerTimeout = AgentCommands.patience; look.setupTimeout = AgentCommands.setupPatience
        look.check()
        await settle { look.page == .checking }
        guard case .status = look.page else {
            nextTry[p.id] = Date().addingTimeInterval(20)
            if phases[p.id] != .waiting { phases[p.id] = .waiting }
            return
        }
        var lines: [String] = [], ok = true
        if wish.claude {
            phases[p.id] = .working("Installing Claude Code")
            var r = ClaudeRequest()
            r.desktop = false                                     // the terminal's Claude Code: the desktop app is Claude Install…'s
            let token = wish.token.components(separatedBy: .whitespacesAndNewlines).joined()
            if !token.isEmpty {
                r.token = token; r.account = wish.account.isEmpty ? "claude" : wish.account; r.alias = look.status.nextAlias
                r.makeDefault = !look.status.defaultToken && !look.status.browserLogin
            }
            look.run(r)
            await settle { look.page == .working }
            if let o = look.outcome, o.ok {
                let version = o.status?.version ?? ""
                lines.append("Claude Code\(version.isEmpty ? "" : " \(version)")" + (o.alias.isEmpty ? ": installed; sign in inside (claude)" : ": signed in as \(o.account), alias \(o.alias)" + (o.makeDefault ? " (and claude, cc)" : "")))
            } else {
                ok = false; lines.append("Claude Code: " + Self.failure(look.outcome?.steps ?? look.steps))
            }
        }
        if wish.codex {
            phases[p.id] = .working("Installing Codex")
            let login = wish.codexLogin ? CodexLogin.login(at: CodexInstall.macLogin) : nil
            if p.kind == .windows {
                let m = CodexInstallModel(machine: p)
                m.answerTimeout = AgentCommands.patience; m.setupTimeout = AgentCommands.setupPatience
                m.check()
                await settle { m.page == .checking }
                if case .status = m.page {
                    m.copyLogin = login != nil
                    m.run()
                    await settle { m.page == .working }
                }
                if let o = m.outcome, o.ok {
                    lines.append("Codex\((o.status?.version ?? "").isEmpty ? "" : " \(o.status?.version ?? "")"): installed, alias cx" + (o.status?.signedIn == true ? ", signed in" : "; sign in inside (codex)"))
                } else {
                    ok = false
                    if case .unreachable(let why) = m.page { lines.append("Codex: \(why)") } else { lines.append("Codex: " + Self.failure(m.outcome?.steps ?? m.steps)) }
                }
            } else {
                let m = ClaudeInstallModel(machine: p)
                m.answerTimeout = AgentCommands.patience; m.setupTimeout = AgentCommands.setupPatience
                var r = ClaudeRequest()
                r.claude = false; r.codexInstall = true; r.codexLogin = login.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                m.run(r)
                await settle { m.page == .working }
                if let o = m.outcome, o.ok {
                    let s = o.status
                    lines.append("Codex\((s?.codexVersion ?? "").isEmpty ? "" : " \(s?.codexVersion ?? "")"): installed, alias cx" + (s?.codexLogin == true ? ", signed in" : "; sign in inside (codex)"))
                } else {
                    ok = false; lines.append("Codex: " + Self.failure(m.outcome?.steps ?? m.steps))
                }
            }
        }
        // done with, however it went: the token does not stay on the Mac (Claude Install… and Codex Install… try again)
        Self.forget(p.machineFolder)
        nextTry[p.id] = nil
        phases[p.id] = ok ? .done(lines) : .failed(lines)
    }
}
