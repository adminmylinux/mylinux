import Foundation

/// "Install Claude Code" and "Install Codex" in the dialog of a new Omarchy or Windows machine (FirstStartSheet): what
/// was ticked there is carried out by the launcher once the machine is up for the first time, with nobody opening
/// Claude Install… or Codex Install…. The terminal versions: Claude Code with its status line (in Windows also Git,
/// which it works through), and Codex with the alias cx; not the desktop apps.
///
/// The wish waits in the machine's folder (`first-start.tools`, for the Mac user alone: it can hold the Claude token
/// that was typed into the dialog) from Create to the machine's first start.
///
/// An Omarchy is set up in its first boot, before its desktop exists (`prepareBoot`): at that start the launcher
/// writes the setup script and its request beside the new disk, run-omarchy.sh puts them into it
/// (tools/omarchy-bake-answers.sh), and Omarchy's first-start setup runs them in the new account
/// (omarchy/answers/provision). So the first terminal anybody can open has cc, cc1 and cx. Set up after the desktop
/// is there, as it was at first, a terminal opened in the desktop's first seconds had Omarchy's own cx, which is
/// Claude Code, and no cc: the user met exactly that, twice. Once the machine's helper answers, the launcher looks at
/// what is there, puts right what the boot could not (the status line needs the network), and says how it went.
///
/// A Windows, and an Omarchy whose disk could not be written into, is set up when the machine's helper first answers,
/// which is when its desktop is there (a Windows that installed itself and restarted). Then the wizards' own models
/// do the work (as `mylinux claude` and `mylinux codex` drive them, AgentCommands), the file is removed whatever came
/// of it, and the machine's page says how it went.
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
    nonisolated static func forget(_ machineFolder: URL) {
        for url in [file(machineFolder), bootRequest(machineFolder), bootScript(machineFolder), bootMarker(machineFolder)] { try? FileManager.default.removeItem(at: url) }
    }

    // ---- an Omarchy: in its first boot ---------------------------------------------------------------------------------
    /// What the first boot was asked to set up (nothing secret): kept until the launcher has looked at how it went.
    struct Boot: Codable, Equatable { var claude = false; var codex = false; var token = false }
    nonisolated static func bootRequest(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("first-start.tools-request") }
    nonisolated static func bootScript(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("first-start.tools-script") }
    nonisolated static func bootMarker(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("first-start.tools-boot") }
    nonisolated static func boot(_ machineFolder: URL) -> Boot? {
        (try? Data(contentsOf: bootMarker(machineFolder))).flatMap { try? JSONDecoder().decode(Boot.self, from: $0) }
    }
    /// The request the setup script takes for a wish, in a machine that has nothing yet: the subscription as cc1 and
    /// as plain claude's login, Codex with the login when one is given.
    nonisolated static func request(for wish: Wish, codexLogin: String, defaultAliases: [[String: String]]) -> [String: Any] {
        var r = ClaudeRequest()
        r.claude = wish.claude
        let token = wish.token.components(separatedBy: .whitespacesAndNewlines).joined()
        if wish.claude, !token.isEmpty { r.token = token; r.account = wish.account.isEmpty ? "claude" : wish.account; r.alias = "cc1"; r.makeDefault = true }
        if wish.codex { r.codexInstall = true; r.codexLogin = wish.codexLogin ? codexLogin : "" }
        return r.json(defaultAliases: defaultAliases)
    }
    /// Runner.start, for an Omarchy whose disk is still to be made: the wish becomes a request and the setup script
    /// beside the disk, for run-omarchy.sh to put into it. Anything missing, and the wish simply waits for the desktop.
    /// (`script`, `loginFile`: a test's; the launcher's own script and this Mac's Codex login otherwise, read only when asked for.)
    nonisolated static func prepareBoot(_ p: Profile, script given: String? = nil, loginFile: URL = CodexInstall.macLogin) {
        guard p.kind == .omarchy, !p.desktopCreated, !FileManager.default.fileExists(atPath: p.appsDisk),
              let wish = kept(p.machineFolder), !wish.isEmpty, let script = given ?? ClaudeInstall.bundledScript() else { return }
        let folder = p.machineFolder, fm = FileManager.default
        let login = wish.codex && wish.codexLogin ? CodexLogin.login(at: loginFile) : nil
        let json = request(for: wish, codexLogin: login.flatMap { String(data: $0, encoding: .utf8) } ?? "", defaultAliases: ClaudeInstall.defaultAliases())
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let marker = try? JSONEncoder().encode(Boot(claude: wish.claude, codex: wish.codex, token: wish.claude && !wish.token.isEmpty)) else { return }
        for url in [bootRequest(folder), bootScript(folder), bootMarker(folder)] { try? fm.removeItem(at: url) }
        guard fm.createFile(atPath: bootRequest(folder).path, contents: data, attributes: [.posixPermissions: 0o600]),
              (try? script.write(to: bootScript(folder), atomically: true, encoding: .utf8)) != nil,
              (try? marker.write(to: bootMarker(folder))) != nil else {
            for url in [bootRequest(folder), bootScript(folder), bootMarker(folder)] { try? fm.removeItem(at: url) }
            return
        }
    }

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

    /// An Omarchy that was set up in its first boot, now that its helper answers: what is there, said on the machine's
    /// page; what the boot could not do without the network (the status line) is done now.
    private func lookAfterBoot(_ boot: Boot, _ p: Profile) async {
        let look = ClaudeInstallModel(machine: p)
        look.answerTimeout = AgentCommands.patience; look.setupTimeout = AgentCommands.setupPatience
        look.check()
        await settle { look.page == .checking }
        guard case .status = look.page else {
            nextTry[p.id] = Date().addingTimeInterval(20)
            if phases[p.id] != .waiting { phases[p.id] = .waiting }
            return
        }
        var s = look.status
        if boot.claude, !s.repairs.isEmpty, !(boot.token && !s.hasToken) {
            phases[p.id] = .working("Finishing Claude Code")
            var r = ClaudeRequest(); r.desktop = false; r.notify = true
            look.run(r)
            await settle { look.page == .working }
            s = look.outcome?.status ?? s
        }
        var lines: [String] = [], ok = true
        if boot.claude {
            if boot.token && !s.hasToken { ok = false; lines.append("Claude Code: the setup in the machine's first boot did not get to the subscription") }
            else if let a = s.accounts.first { lines.append("Claude Code\(s.version.isEmpty ? "" : " \(s.version)"): signed in as \(a.account), alias \(a.alias)" + (s.defaultToken ? " (and claude, cc)" : "")) }
            else { lines.append("Claude Code\(s.version.isEmpty ? "" : " \(s.version)"): installed; sign in inside (claude)") }
        }
        if boot.codex {
            if s.codexInstalled && s.codexCx { lines.append("Codex\(s.codexVersion.isEmpty ? "" : " \(s.codexVersion)"): installed, alias cx" + (s.codexLogin ? ", signed in" : "; sign in inside (codex)")) }
            else { ok = false; lines.append("Codex: the setup in the machine's first boot did not finish") }
        }
        try? FileManager.default.removeItem(at: Self.bootMarker(p.machineFolder))
        nextTry[p.id] = nil
        phases[p.id] = ok ? .done(lines) : .failed(lines)
    }

    /// RunManager's tick, for a running Omarchy or Windows: a wish is carried out when the machine's helper answers.
    func follow(_ p: Profile, runner: Runner, now: Date = Date()) {
        guard FirstStartSheet.asks(p.kind), !busy.contains(p.id) else { return }
        guard let wish = Self.kept(p.machineFolder) else {
            // nothing waits; unless the first boot did the work (an Omarchy): then how that went is looked at
            guard let boot = Self.boot(p.machineFolder) else {
                if case .waiting = phases[p.id] { phases[p.id] = nil }   // forgotten meanwhile
                return
            }
            guard runner.state == .running || runner.state == .inUseElsewhere, OmarchyUnattended.stage(p) != .settingUp else { return }
            if let t = nextTry[p.id], now < t { return }
            busy.insert(p.id)
            Task { @MainActor in
                await lookAfterBoot(boot, p)
                busy.remove(p.id)
            }
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
        let token = wish.token.components(separatedBy: .whitespacesAndNewlines).joined()
        let login = wish.codex && wish.codexLogin ? CodexLogin.login(at: CodexInstall.macLogin) : nil
        /// Claude Code's part of a request: the terminal's, with the subscription as the next free alias when a token was given.
        func claudeRequest() -> ClaudeRequest {
            var r = ClaudeRequest()
            r.desktop = false                                     // the terminal's Claude Code: the desktop app is Claude Install…'s
            if !token.isEmpty {
                r.token = token; r.account = wish.account.isEmpty ? "claude" : wish.account; r.alias = look.status.nextAlias
                r.makeDefault = !look.status.defaultToken && !look.status.browserLogin
            }
            return r
        }
        func claudeLine(_ o: ClaudeOutcome) -> String {
            let version = o.status?.version ?? ""
            return "Claude Code\(version.isEmpty ? "" : " \(version)")" + (o.alias.isEmpty ? ": installed; sign in inside (claude)" : ": signed in as \(o.account), alias \(o.alias)" + (o.makeDefault ? " (and claude, cc)" : ""))
        }
        if p.kind != .windows {
            // one request for both: the script inside does Claude Code's steps and then Codex's, and tells the desktop
            // once when it begins and once when a new terminal has them
            phases[p.id] = .working(wish.claude && wish.codex ? "Installing Claude Code and Codex" : wish.claude ? "Installing Claude Code" : "Installing Codex")
            var r = wish.claude ? claudeRequest() : ClaudeRequest()
            r.claude = wish.claude; r.notify = true
            if wish.codex { r.codexInstall = true; r.codexLogin = login.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
            look.run(r)
            await settle { look.page == .working }
            let steps = look.outcome?.steps ?? look.steps
            let failed = steps.filter { $0.state == "failed" }
            if wish.claude {
                let mine = failed.filter { !$0.step.hasPrefix("codex") }
                if let o = look.outcome, mine.isEmpty, o.status != nil { lines.append(claudeLine(o)) } else { ok = false; lines.append("Claude Code: " + Self.failure(mine.isEmpty ? steps : mine)) }
            }
            if wish.codex {
                let mine = failed.filter { $0.step.hasPrefix("codex") }
                if let s = look.outcome?.status, mine.isEmpty, look.outcome?.ok == true || failed.allSatisfy({ !$0.step.hasPrefix("codex") }) {
                    lines.append("Codex\(s.codexVersion.isEmpty ? "" : " \(s.codexVersion)"): installed, alias cx" + (s.codexLogin ? ", signed in" : "; sign in inside (codex)"))
                } else { ok = false; lines.append("Codex: " + Self.failure(mine.isEmpty ? steps : mine)) }
            }
        } else {
            if wish.claude {
                phases[p.id] = .working("Installing Claude Code")
                look.run(claudeRequest())
                await settle { look.page == .working }
                if let o = look.outcome, o.ok { lines.append(claudeLine(o)) } else { ok = false; lines.append("Claude Code: " + Self.failure(look.outcome?.steps ?? look.steps)) }
            }
            if wish.codex {
                phases[p.id] = .working("Installing Codex")
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
            }
        }
        // done with, however it went: the token does not stay on the Mac (Claude Install… and Codex Install… try again)
        Self.forget(p.machineFolder)
        nextTry[p.id] = nil
        phases[p.id] = ok ? .done(lines) : .failed(lines)
    }
}
