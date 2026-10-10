import Foundation

/// Claude Install… and Codex Install… from the command line (`mylinux claude NAME …`, `mylinux codex NAME …`): the
/// wizards' own models and scripts with no window, so a coding agent can do for a desktop machine what the wizards
/// do: look at what is there, install Claude Code and Codex, add a subscription, sign Codex in.
///
/// What is secret never passes through the command or whoever runs it. A Claude subscription's token is named, not
/// given: `--token-file FILE --token-name NAME` is a file of NAME=value lines on this Mac and the entry in it, which
/// the launcher reads here and hands to the machine as the wizard does. Codex is signed in with this Mac's own login
/// only on `--login-from-mac`, and OpenAI's desktop app comes from the Microsoft Store only with `--accept-store-terms`:
/// both are the user's to say, and the agents' skill tells an agent to pass them only on the user's word.
///
/// A question is answered at once with where it stands ("checking", "working"); the command asks again (`--poll`)
/// until it is "ready", "finished" or could not be reached.
@MainActor enum AgentCommands {
    private static var claude: [UUID: ClaudeInstallModel] = [:]
    /// Codex in a Linux desktop goes through the script Claude Code's setup has there (claude_setup.py), with a model of its own.
    private static var linuxCodex: [UUID: ClaudeInstallModel] = [:]
    private static var windowsCodex: [UUID: CodexInstallModel] = [:]
    /// Why an install that was asked for did not begin, until the next question about it is answered with it.
    private static var problems: [String: String] = [:]
    private static var tasks: [String: Task<Void, Never>] = [:]
    /// An install that was asked for and has not begun inside yet (the look comes first): still "checking" to who asks.
    private static var onTheWay: Set<String> = []
    /// How long a machine has to answer once its helper has taken a question. Nobody is watching a window here, and a
    /// Windows that has just been installed starts its first PowerShell in a minute or more (80 seconds in a test).
    static let patience: TimeInterval = 240
    /// How long a setup may take inside: Claude Code is 250 MB that a new Windows then checks, Git and the desktop
    /// apps come after it, and a machine in its first hour is slow at all of it.
    static let setupPatience: TimeInterval = 75 * 60

    /// One entry of a file of NAME=value lines (an .env file), by its name: its value, or why not, in words that
    /// never have the value in them.
    nonisolated static func secret(named name: String, inFile path: String) -> (value: String?, problem: String?) {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return (nil, "--token-name is the entry's name: letters, digits and _") }
        let file = (path as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return (nil, "\(path) cannot be read (a file of NAME=value lines on this Mac)") }
        var found: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "="), line[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) { value = String(value.dropFirst().dropLast()) }
            found.append(value)
        }
        if found.isEmpty { return (nil, "\(path) has no entry named \(name)") }
        if found.count > 1 { return (nil, "\(path) names \(name) \(found.count) times: which one is meant?") }
        if found[0].isEmpty { return (nil, "\(name) in \(path) is empty") }
        return (found[0], nil)
    }

    static func handle(_ tool: String, _ w: CLI.Words, store: ProfileStore = .shared, settings: AppSettings = .shared) -> CLI.Reply {
        guard let name = w.plain.first else { return .failed("which machine? mylinux \(tool) <name> [--install …]", code: 2) }
        guard let p = CLIService.find(name, store: store) else {
            return .failed("no machine named \"\(name)\" (there are: \(store.profiles.map(\.name).joined(separator: ", ")))")
        }
        guard p.kind == .omarchy || p.kind == .windows else {
            return .failed("mylinux \(tool) is for an Omarchy or a Windows machine. In a server (tiny, alpine, debian) it is installed over ssh: the skill's \"Claude Code in a server\"", code: 2)
        }
        let key = "\(p.id.uuidString)-\(tool)"
        if !w.flags.contains("poll") {
            guard CLIService.describe(p, settings: settings)["state"] as? String == "running" else {
                return .failed("\"\(p.name)\" is not running: mylinux start \"\(p.name)\" --wait, then ask again")
            }
            if let problem = begin(tool, p, w, key: key) { return problem }
        }
        return tool == "claude" ? claudeSaid(p, key: key) : codexSaid(p, key: key)
    }

    /// Starts the look, or the install, unless one is on its way. What is wrong with the words, or nil.
    private static func begin(_ tool: String, _ p: Profile, _ w: CLI.Words, key: String) -> CLI.Reply? {
        let install = w.flags.contains("install")
        problems[key] = nil; onTheWay.remove(key)
        if tool == "claude" {
            let m = claude[p.id] ?? ClaudeInstallModel(machine: p); claude[p.id] = m
            m.answerTimeout = patience; m.setupTimeout = setupPatience
            if m.page == .working { return nil }                    // a setup is running: the answer is how far it is
            var request = ClaudeRequest()
            if let file = w.values["token-file"] {
                guard install else { return .failed("--token-file goes with --install", code: 2) }
                guard let entry = w.values["token-name"] else { return .failed("--token-name NAME: the entry of \(file) that holds the token (the file has NAME=value lines)", code: 2) }
                guard let account = w.values["account"]?.trimmingCharacters(in: .whitespaces), !account.isEmpty else {
                    return .failed("--account NAME: what this subscription is called (one word; the status line shows it)", code: 2)
                }
                let (token, problem) = secret(named: entry, inFile: file)
                guard let token else { return .failed(problem ?? "the token could not be read", code: 2) }
                request.token = token; request.account = account; request.alias = w.values["alias"] ?? "cc1"
                if let problem = request.problem(catalogAliases: m.catalogAliases) { return .failed(problem.replacingOccurrences(of: "Paste the token from claude setup-token.", with: "\(entry) holds no token"), code: 2) }
                if w.values["alias"] == nil { request.alias = "" }                                   // the next free one, known after the look
            } else if ["token-name", "account", "alias"].contains(where: { w.values[$0] != nil }) || w.flags.contains("default") || w.flags.contains("not-default") {
                return .failed("--token-name, --account, --alias and --default go with --token-file FILE (the token is named, never given)", code: 2)
            }
            m.check()
            tasks[key]?.cancel()
            guard install else { return nil }
            let makeDefault: Bool? = w.flags.contains("default") ? true : w.flags.contains("not-default") ? false : nil
            onTheWay.insert(key)
            tasks[key] = Task { @MainActor in
                while m.page == .checking { try? await Task.sleep(nanoseconds: 300_000_000) }
                guard !Task.isCancelled else { return }
                defer { onTheWay.remove(key) }
                guard case .status = m.page else { return }                          // not reached: the page says why
                var r = request
                if !r.cleanToken.isEmpty {
                    if r.alias.isEmpty { r.alias = m.status.nextAlias }
                    r.makeDefault = makeDefault ?? (!m.status.defaultToken && !m.status.browserLogin)
                    if let problem = r.problem(catalogAliases: m.catalogAliases) { problems[key] = problem; return }
                }
                m.run(r.cleanToken.isEmpty ? nil : r)
            }
            return nil
        }
        // codex
        let loginAsked = w.flags.contains("login-from-mac")
        if (loginAsked || w.flags.contains("desktop") || w.flags.contains("accept-store-terms")) && !install {
            return .failed("--login-from-mac and --desktop go with --install", code: 2)
        }
        var login: Data?
        if loginAsked {
            guard let data = CodexLogin.login(at: CodexInstall.macLogin) else {
                return .failed("this Mac has no Codex login to give (~/.codex/auth.json): sign Codex in on the Mac first (codex login), or leave --login-from-mac out and sign in inside the machine")
            }
            login = data
        }
        if p.kind == .windows {
            let m = windowsCodex[p.id] ?? CodexInstallModel(machine: p); windowsCodex[p.id] = m
            m.answerTimeout = patience; m.setupTimeout = setupPatience
            if m.page == .working { return nil }
            m.check()
            tasks[key]?.cancel()
            guard install else { return nil }
            let desktop = w.flags.contains("desktop"), terms = w.flags.contains("accept-store-terms")
            onTheWay.insert(key)
            tasks[key] = Task { @MainActor in
                while m.page == .checking { try? await Task.sleep(nanoseconds: 300_000_000) }
                guard !Task.isCancelled else { return }
                defer { onTheWay.remove(key) }
                guard case .status = m.page else { return }
                m.copyLogin = login != nil && m.macHasLogin
                m.desktop = desktop; m.storeTerms = terms
                m.run()
            }
            return nil
        }
        if w.flags.contains("desktop") { return .failed("--desktop is OpenAI's desktop app for Windows: an Omarchy has Codex in its terminal", code: 2) }
        let m = linuxCodex[p.id] ?? ClaudeInstallModel(machine: p); linuxCodex[p.id] = m
        m.answerTimeout = patience; m.setupTimeout = setupPatience
        if m.page == .working { return nil }
        tasks[key]?.cancel()
        guard install else { m.check(); return nil }
        var r = ClaudeRequest()
        r.claude = false; r.codexInstall = true; r.codexLogin = login.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        m.run(r)
        return nil
    }

    private static func rows(_ steps: [ClaudeStep]) -> [[String: Any]] { steps.map { ["title": $0.title, "state": $0.state, "detail": $0.detail] } }
    /// A setup that did not end well, in a sentence: its first failed step.
    private static func failure(_ steps: [ClaudeStep]) -> String {
        guard let s = steps.first(where: { $0.state == "failed" }) else { return "the setup did not end well" }
        return s.detail.isEmpty ? "\(s.title): failed" : "\(s.title): \(s.detail)"
    }
    private static func unreachable(_ p: Profile, _ tool: String, _ why: String) -> CLI.Reply {
        CLI.Reply(code: 1, json: ["ok": false, "error": why, "machine": p.name, tool: ["state": "unreachable"]])
    }

    private static func claudeSaid(_ p: Profile, key: String) -> CLI.Reply {
        if let problem = problems[key] { return CLI.Reply(code: 2, json: ["ok": false, "error": problem, "machine": p.name, "claude": ["state": "refused"]]) }
        guard let m = claude[p.id] else { return .failed("nothing was asked about Claude Code in \"\(p.name)\" yet: mylinux claude \"\(p.name)\"") }
        func facts(_ s: ClaudeStatus) -> [String: Any] {
            var c: [String: Any] = ["installed": s.installed, "version": s.version, "signedIn": s.signedIn, "statusLine": s.statusLineOK,
                                    "default": ["token": s.defaultToken, "account": s.defaultAccount, "browserLogin": s.browserLogin],
                                    "subscriptions": s.accounts.map { ["alias": $0.alias, "account": $0.account] }, "toDo": s.repairs]
            if s.windows { c["git"] = s.git; c["desktopApp"] = ["installed": s.desktopInstalled, "version": s.desktopVersion, "onTaskbar": s.desktopPinned] }
            return c
        }
        var c: [String: Any] = [:]
        switch m.page {
        case .checking: c["state"] = "checking"
        case .unreachable(let why): return unreachable(p, "claude", why)
        case .status, .form: c = facts(m.status); c["state"] = onTheWay.contains(key) ? "checking" : "ready"
        case .working: c["state"] = "working"; c["steps"] = rows(m.steps)
        case .finished:
            c = facts(m.outcome?.status ?? m.status); c["state"] = "finished"; c["steps"] = rows(m.outcome?.steps ?? m.steps)
            guard let o = m.outcome, o.ok else { return CLI.Reply(code: 1, json: ["ok": false, "error": failure(m.outcome?.steps ?? m.steps), "machine": p.name, "claude": c]) }
            if !o.alias.isEmpty { c["added"] = ["alias": o.alias, "account": o.account, "default": o.makeDefault] }
        }
        return .ok(["machine": p.name, "claude": c])
    }

    private static func codexSaid(_ p: Profile, key: String) -> CLI.Reply {
        if let problem = problems[key] { return CLI.Reply(code: 2, json: ["ok": false, "error": problem, "machine": p.name, "codex": ["state": "refused"]]) }
        let macHasLogin = CodexLogin.login(at: CodexInstall.macLogin) != nil
        var c: [String: Any] = [:]
        if p.kind == .windows {
            guard let m = windowsCodex[p.id] else { return .failed("nothing was asked about Codex in \"\(p.name)\" yet: mylinux codex \"\(p.name)\"") }
            func facts(_ s: CodexStatus) -> [String: Any] {
                ["installed": s.installed, "version": s.version, "signedIn": s.signedIn, "cx": s.cx, "toDo": s.repairs,
                 "desktopApp": ["installed": s.desktopInstalled, "version": s.desktopVersion], "macHasLogin": macHasLogin]
            }
            switch m.page {
            case .checking: c["state"] = "checking"
            case .unreachable(let why): return unreachable(p, "codex", why)
            case .status: c = facts(m.status); c["state"] = onTheWay.contains(key) ? "checking" : "ready"
            case .working: c["state"] = "working"; c["steps"] = rows(m.steps)
            case .finished:
                c = facts(m.outcome?.status ?? m.status); c["state"] = "finished"; c["steps"] = rows(m.outcome?.steps ?? m.steps)
                guard m.outcome?.ok == true else { return CLI.Reply(code: 1, json: ["ok": false, "error": failure(m.outcome?.steps ?? m.steps), "machine": p.name, "codex": c]) }
            }
            return .ok(["machine": p.name, "codex": c])
        }
        guard let m = linuxCodex[p.id] else { return .failed("nothing was asked about Codex in \"\(p.name)\" yet: mylinux codex \"\(p.name)\"") }
        func facts(_ s: ClaudeStatus) -> [String: Any] {
            ["installed": s.codexInstalled, "version": s.codexVersion, "signedIn": s.codexLogin, "cx": s.codexCx, "macHasLogin": macHasLogin]
        }
        switch m.page {
        case .checking: c["state"] = "checking"
        case .unreachable(let why): return unreachable(p, "codex", why)
        case .status, .form: c = facts(m.status); c["state"] = "ready"
        case .working: c["state"] = "working"; c["steps"] = rows(m.steps)
        case .finished:
            c = facts(m.outcome?.status ?? m.status); c["state"] = "finished"; c["steps"] = rows(m.outcome?.steps ?? m.steps)
            guard m.outcome?.ok == true else { return CLI.Reply(code: 1, json: ["ok": false, "error": failure(m.outcome?.steps ?? m.steps), "machine": p.name, "codex": c]) }
        }
        return .ok(["machine": p.name, "codex": c])
    }
}
