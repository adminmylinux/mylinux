import AppKit
import SwiftUI

/// Claude Install… (under Apps… in an Omarchy window's ⌘ menu): a wizard on the Mac that looks at Claude Code inside
/// the machine and sets it up with a long-lived token, with no terminal and no browser. Its first page says what is
/// there: Claude Code and its version, the subscriptions saved as aliases (cc1, cc2, …) and whether the status line
/// shows the account of the one in use; what is missing it offers to install or update. Without a token it asks for
/// one (from `claude setup-token`), a name for the account and optionally a myLinux API key, then installs Claude
/// Code, the alias and the status line.
///
/// The work inside is server-apps/claude_setup.py, which the launcher writes into the machine's Mac share
/// (.mylinux/claude) with the request beside it; Omarchy's session agent (omarchy/session) starts it on "claude status
/// <id>" or "claude apply <id>" in the share's control folder, and the wizard reads the status, the steps as they go
/// and the outcome back from the share. The token is in the share only until the script has read it (it removes the
/// request first), in a file its owner alone reads; a request nobody took is removed after a minute.
///
/// A Windows machine has the wizard too (0.7.72). Windows reads no Mac folder, so its files are in a folder on the Mac
/// that only stands in for a share (WindowsLink: <machine folder>/link), the script is windows/claude_codex_setup.ps1,
/// and the launcher's helper beside the machine carries the question and the answers over the machine's own port.
enum ClaudeInstall {
    static let script = "claude_setup.py"
    static func folder(_ share: String) -> URL { URL(fileURLWithPath: share).appendingPathComponent(".mylinux/claude", isDirectory: true) }
    static func control(_ share: String) -> URL { URL(fileURLWithPath: share).appendingPathComponent("mylinux-tools/control", isDirectory: true) }
    static func statusFile(_ share: String, _ id: String) -> URL { folder(share).appendingPathComponent("status-\(id).json") }
    static func requestFile(_ share: String, _ id: String) -> URL { folder(share).appendingPathComponent("request-\(id).json") }
    static func progressFile(_ share: String, _ id: String) -> URL { folder(share).appendingPathComponent("progress-\(id).jsonl") }
    static func resultFile(_ share: String, _ id: String) -> URL { folder(share).appendingPathComponent("result-\(id).json") }
    /// How long a request with a token may wait in the share for the script.
    static let requestLifetime: TimeInterval = 60

    /// A name for one question and its answer: the files of two runs never meet, and a file the machine has not seen
    /// before is never one it remembers.
    static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16).description }

    /// The script built into the app (Contents/Resources/server-apps), or the checkout's when run from a build: the
    /// wizard and the script it talks to are one version.
    static func bundledScript() -> String? {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("server-apps"),
                    Paths.buildRepo.map { URL(fileURLWithPath: $0).appendingPathComponent("server-apps") }]
        for case let dir? in dirs {
            if let s = try? String(contentsOf: dir.appendingPathComponent(script), encoding: .utf8), s.contains("def apply(") { return s }
        }
        return nil
    }

    /// The catalog's aliases that are on from the start (cc, cx): a machine whose aliases file is not there yet gets
    /// them with the subscription's, as myLinux Apps would have made the file.
    static func defaultAliases(catalog: String? = ServerApps.bundled()?["catalog.json"]) -> [[String: String]] {
        guard let data = catalog?.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aliases = obj["aliases"] as? [[String: Any]] else { return [] }
        return aliases.compactMap { a in
            guard a["default"] as? Bool == true, let name = a["name"] as? String, let command = a["command"] as? String else { return nil }
            return ["name": name, "command": command]
        }
    }

    /// The script into the share, and yesterday's answers out of it: nil, or what went wrong.
    static func prepare(_ share: String, script text: String? = bundledScript()) -> String? {
        guard !share.isEmpty else { return "Claude Install needs the machine's share folder (its page › Files & sharing)." }
        guard let text else { return "The launcher has no copy of the Claude setup script." }
        do {
            try FileManager.default.createDirectory(at: folder(share), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: control(share), withIntermediateDirectories: true)
            try text.write(to: folder(share).appendingPathComponent(script), atomically: true, encoding: .utf8)
        } catch {
            return "Could not write into \(folder(share).path): \(error.localizedDescription)"
        }
        sweep(share)
        return nil
    }

    static func commandFile(_ share: String, _ id: String) -> URL { control(share).appendingPathComponent("claude-\(id).cmd") }

    /// "claude status <id>" or "claude apply <id>" for Omarchy's session agent, which looks every second and takes
    /// (removes) what it finds.
    static func ask(_ share: String, _ what: String, _ id: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: control(share), withIntermediateDirectories: true)
            try "claude \(what) \(id)\n".write(to: commandFile(share, id), atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    /// The request, for its owner only (the share shows the Mac user's files as the machine's user).
    static func writeRequest(_ request: ClaudeRequest, id: String, share: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: request.json(defaultAliases: defaultAliases()), options: [.sortedKeys]) else { return false }
        let url = requestFile(share, id), tmp = folder(share).appendingPathComponent(".request-\(id).tmp")
        do {
            try FileManager.default.createDirectory(at: folder(share), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            try FileManager.default.moveItem(at: tmp, to: url)
            return true
        } catch { try? FileManager.default.removeItem(at: tmp); return false }
    }

    static func status(_ share: String, _ id: String) -> ClaudeStatus? {
        (try? Data(contentsOf: statusFile(share, id))).flatMap(ClaudeStatus.parse)
    }

    /// The steps so far: the last line of each step, in the order they began.
    static func steps(_ share: String, _ id: String) -> [ClaudeStep] {
        guard let text = try? String(contentsOf: progressFile(share, id), encoding: .utf8) else { return [] }
        return ClaudeStep.parse(lines: text)
    }

    static func outcome(_ share: String, _ id: String) -> ClaudeOutcome? {
        (try? Data(contentsOf: resultFile(share, id))).flatMap(ClaudeOutcome.parse)
    }

    /// A request nobody took (the agent is an older one, or nobody is signed in to the desktop) and what earlier runs
    /// left: out of the share.
    static func sweep(_ share: String, now: Date = Date()) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: folder(share), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let name = url.lastPathComponent
            guard name != script, name != WindowsLink.scriptName, let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            let age = now.timeIntervalSince(written)
            let request = name.hasPrefix("request-") || name.hasPrefix(".request-")
            if request ? age > requestLifetime : age > 3600 { try? fm.removeItem(at: url) }
        }
    }

    static func forget(_ share: String, _ id: String) {
        // with the command, when nobody took it: an agent that starts later is not asked a question nobody waits for
        for url in [commandFile(share, id), statusFile(share, id), requestFile(share, id), progressFile(share, id), resultFile(share, id)] { try? FileManager.default.removeItem(at: url) }
    }
}

/// What claude_setup.py found inside the machine (its "status").
struct ClaudeStatus: Equatable {
    struct Account: Equatable, Identifiable {
        var alias: String, account: String, token: Bool, aliasLine: Bool
        var id: String { alias }
    }
    var installed = false, version = "", path = ""
    /// Plain `claude` and the alias cc: a token every shell loads (and its account's name), or a login made in the browser.
    var defaultToken = false, defaultAccount = "", browserLogin = false
    var accounts: [Account] = []
    var aliasNames: [String] = [], aliasesLoaded = false
    var lineScript = false, lineShowsAccount = false, lineConfigured = false, lineCommand = ""
    var apiKey = false
    /// A Windows machine's answer (windows/claude_codex_setup.ps1): the aliases are .cmd files on the PATH there, and
    /// Claude Code works through Git for Windows.
    var windows = false, git = true
    /// Claude, the desktop app, in a Windows machine: installed with Claude Code, and pinned to the taskbar once
    /// (`desktopPinnedOnce`: taken off the taskbar by hand afterwards, it is not offered again).
    var desktopInstalled = false, desktopVersion = "", desktopPinned = false, desktopPinnedOnce = false
    /// Codex in a Linux machine, which the same script looks at (`mylinux codex NAME`): installed, a login file there
    /// (never what is in it), and the alias cx.
    var codexInstalled = false, codexVersion = "", codexLogin = false, codexCx = false

    static func parse(_ data: Data) -> ClaudeStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ClaudeStatus(obj)
    }

    init() {}
    init?(_ obj: [String: Any]) {
        guard let claude = obj["claude"] as? [String: Any], let installed = claude["installed"] as? Bool else { return nil }
        self.installed = installed
        version = claude["version"] as? String ?? ""; path = claude["path"] as? String ?? ""
        let d = obj["default"] as? [String: Any] ?? [:]
        defaultToken = d["token"] as? Bool ?? false; defaultAccount = d["account"] as? String ?? ""; browserLogin = d["browser"] as? Bool ?? false
        accounts = (obj["accounts"] as? [[String: Any]] ?? []).compactMap { a in
            (a["alias"] as? String).map { Account(alias: $0, account: a["account"] as? String ?? "", token: a["token"] as? Bool ?? false, aliasLine: a["aliasLine"] as? Bool ?? false) }
        }
        let aliases = obj["aliases"] as? [String: Any] ?? [:]
        aliasNames = aliases["names"] as? [String] ?? []; aliasesLoaded = aliases["loaded"] as? Bool ?? false
        let line = obj["statusLine"] as? [String: Any] ?? [:]
        lineScript = line["script"] as? Bool ?? false; lineShowsAccount = line["showsAccount"] as? Bool ?? false
        lineConfigured = line["configured"] as? Bool ?? false; lineCommand = line["command"] as? String ?? ""
        apiKey = obj["apiKey"] as? Bool ?? false
        windows = obj["system"] as? String == "windows"; git = obj["git"] as? Bool ?? true
        let desktop = obj["desktop"] as? [String: Any] ?? [:]
        desktopInstalled = desktop["installed"] as? Bool ?? false; desktopVersion = desktop["version"] as? String ?? ""
        desktopPinned = desktop["pinned"] as? Bool ?? false; desktopPinnedOnce = desktop["pinnedOnce"] as? Bool ?? false
        let codex = obj["codex"] as? [String: Any] ?? [:]
        codexInstalled = codex["installed"] as? Bool ?? false; codexVersion = codex["version"] as? String ?? ""
        codexLogin = codex["login"] as? Bool ?? false; codexCx = codex["cx"] as? Bool ?? false
    }

    /// Claude Code here can start without the browser: a subscription with its token, or plain claude's.
    var hasToken: Bool { defaultToken || accounts.contains { $0.token } }
    /// Claude Code here starts signed in: with a token, or with a login made in its browser flow.
    var signedIn: Bool { hasToken || (installed && browserLogin) }
    /// myLinux's status line is the one Claude Code runs: it shows MYLINUX_CLAUDE_ACCOUNT, the account of the token in use.
    var statusLineOK: Bool { lineScript && lineShowsAccount && lineConfigured }
    /// The subscriptions whose alias a new terminal would not have.
    var aliasesMissing: [String] { accounts.filter { !$0.aliasLine }.map(\.alias) }

    /// What Install or Update does without asking for anything (no token needed), in the wizard's words.
    var repairs: [String] {
        var out: [String] = []
        if !installed && hasToken { out.append(git ? "Install Claude Code" : "Install Git for Windows (Claude Code works through it) and Claude Code") }
        if !lineScript || !lineConfigured {
            out.append(lineCommand.isEmpty || lineConfigured ? "Install the status line: folder, git branch, context, limits, cost, model and the account"
                                                             : "Replace the status line that is set (\(lineCommand)) with myLinux's, which shows the account")
        } else if !lineShowsAccount {
            out.append("Update the status line: the one there does not show the account (it is kept as statusline.sh.before-mylinux)")
        }
        if !aliasesMissing.isEmpty { out.append("Add the alias \(aliasesMissing.joined(separator: ", ")) for new terminals") }
        if windows {
            if !desktopInstalled { out.append("Install Claude, the desktop app, and pin it to the taskbar (\(Self.taskbarNote))") }
            else if !desktopPinned && !desktopPinnedOnce { out.append("Pin Claude, the desktop app, to the taskbar (\(Self.taskbarNote))") }
        }
        if !aliasesMissing.isEmpty { return out }
        if !accounts.isEmpty && !aliasesLoaded { out.append(windows ? "Put the aliases' folder (.local\\bin in your user folder) on your PATH" : "Have new terminals load the aliases (~/.bashrc)") }
        return out
    }

    /// What pinning costs, said where it is offered: Windows adds a pin from outside only as Explorer starts.
    static let taskbarNote = "Windows's taskbar starts again for a moment, and open folder windows close"

    /// cc1, then cc2, …: the first that is neither a subscription nor an alias there.
    var nextAlias: String {
        let taken = Set(accounts.map(\.alias) + aliasNames)
        var n = 1
        while taken.contains("cc\(n)") { n += 1 }
        return "cc\(n)"
    }
}

/// What the wizard asks claude_setup.py to do (its "apply"): with a token a subscription is added, without one only
/// what is missing is put in place.
struct ClaudeRequest: Equatable {
    var alias = "", account = "", token = "", apiKey = ""
    /// The token is also the login of plain `claude` and the alias cc.
    var makeDefault = false
    /// Claude Code's own steps (off for `mylinux codex NAME --install` in a Linux machine, which is Codex alone).
    var claude = true
    /// Codex, in a Linux machine: installed when missing, and signed in with this login file's text when given.
    var codexInstall = false, codexLogin = ""

    static let reserved: Set<String> = ["claude", "mylinux-apps"]
    private static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    var cleanToken: String { token.components(separatedBy: .whitespacesAndNewlines).joined() }
    var cleanKey: String { apiKey.components(separatedBy: .whitespacesAndNewlines).joined() }

    /// What is wrong with the fields, as myLinux Apps checks them (the script inside checks them again); nil when
    /// they can go. `aliases` are the catalog's own (cc, cx, gm).
    func problem(catalogAliases: Set<String>) -> String? {
        let a = alias.trimmingCharacters(in: .whitespaces), n = account.trimmingCharacters(in: .whitespaces)
        if cleanToken.isEmpty { return "Paste the token from claude setup-token." }
        if !Self.matches(cleanToken, "^[A-Za-z0-9_-]{20,}$") { return "That does not look like a token from claude setup-token (sk-ant-oat01-…)." }
        if !Self.matches(n, "^[A-Za-z0-9._@-]{1,40}$") { return n.isEmpty ? "Give the account a name: the status line shows it." : "The account name is one word: letters, digits, . _ @ -" }
        if !Self.matches(a, "^[A-Za-z_][A-Za-z0-9_-]{0,31}$") { return "The alias is one word: letters, digits, - and _, starting with a letter." }
        if catalogAliases.contains(a) || Self.reserved.contains(a) { return "\(a) is one of myLinux Apps' own aliases: pick another name (cc1, cc2, …)." }
        if !cleanKey.isEmpty && !Self.matches(cleanKey, "^mlx_[A-Za-z0-9_-]{8,}$") { return "A myLinux API key starts with mlx_ (made at mylinux.app, the API tab); or leave it empty." }
        return nil
    }

    func json(defaultAliases: [[String: String]]) -> [String: Any] {
        var out: [String: Any] = ["defaultAliases": defaultAliases, "statusLine": claude]
        if !claude { out["claude"] = false }
        if codexInstall || !codexLogin.isEmpty { out["codex"] = ["install": codexInstall, "login": codexLogin] }
        if !cleanToken.isEmpty {
            out["alias"] = alias.trimmingCharacters(in: .whitespaces); out["account"] = account.trimmingCharacters(in: .whitespaces)
            out["token"] = cleanToken; out["makeDefault"] = makeDefault
        }
        if !cleanKey.isEmpty { out["apiKey"] = cleanKey }
        return out
    }
}

/// One step of the setup, as the script tells it: running, done, failed or skipped.
struct ClaudeStep: Equatable, Identifiable {
    var step: String, title: String, state: String, detail: String
    var id: String { step }

    init?(_ obj: [String: Any]) {
        guard let step = obj["step"] as? String, let state = obj["state"] as? String else { return nil }
        self.step = step; self.state = state
        title = obj["title"] as? String ?? step; detail = obj["detail"] as? String ?? ""
    }

    static func parse(lines: String) -> [ClaudeStep] {
        var out: [ClaudeStep] = []
        for line in lines.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let s = ClaudeStep(obj) else { continue }
            if let i = out.firstIndex(where: { $0.step == s.step }) { out[i] = s } else { out.append(s) }
        }
        return out
    }
}

struct ClaudeOutcome: Equatable {
    var ok: Bool, steps: [ClaudeStep], alias: String, account: String, makeDefault: Bool, status: ClaudeStatus?

    static func parse(_ data: Data) -> ClaudeOutcome? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ok = obj["ok"] as? Bool else { return nil }
        return ClaudeOutcome(ok: ok, steps: (obj["steps"] as? [[String: Any]] ?? []).compactMap(ClaudeStep.init),
                             alias: obj["alias"] as? String ?? "", account: obj["account"] as? String ?? "",
                             makeDefault: obj["makeDefault"] as? Bool ?? false, status: (obj["status"] as? [String: Any]).flatMap(ClaudeStatus.init))
    }
}

/// The wizard's state and its talk with the machine.
@MainActor final class ClaudeInstallModel: ObservableObject {
    enum Page: Equatable { case checking, unreachable(String), status, form, working, finished }

    let machine: Profile
    @Published var page: Page = .checking
    @Published var status = ClaudeStatus()
    @Published var request = ClaudeRequest()
    @Published var steps: [ClaudeStep] = []
    @Published var outcome: ClaudeOutcome?
    private var task: Task<Void, Never>?
    let catalogAliases: Set<String>
    /// How long the machine has to answer once its agent has taken the question: Omarchy's claude fetches Claude Code
    /// at its first run, so the first `claude --version` in a new machine takes ten seconds and more (the script
    /// gives it thirty).
    var answerTimeout: TimeInterval = 45
    /// How long the setup inside may take once it has begun: an install is a download of a few hundred megabytes.
    var setupTimeout: TimeInterval = 30 * 60
    /// How long the agent has to take a question; it looks every second. (Windows's is asked by the launcher's helper,
    /// once the agent has said in the last seconds that it takes questions: a little longer.)
    var takeTimeout: TimeInterval { min(windows ? 12 : 6, answerTimeout) }

    init(machine: Profile) {
        self.machine = machine
        let catalog = ServerApps.bundled()?["catalog.json"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        catalogAliases = Set(((catalog?["aliases"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
    }

    var windows: Bool { machine.kind == .windows }
    var system: String { windows ? "Windows" : "Omarchy" }
    var notRunning: String { windows ? Self.windowsNotRunning : Self.notRunning }
    var noAnswer: String { windows ? Self.windowsNoAnswer : Self.noAnswer }
    static let windowsNotRunning = "Windows's helper did not take the question. It starts when you are signed in to Windows: sign in there, then try again. A machine that was started by a launcher from before 0.7.72 learns the wizards when it starts again: choose Machine › Restart in its window."
    static let windowsNoAnswer = "Windows's helper took the question and did not answer. Try again; if it stays so, choose Machine › Restart in the machine's window."
    /// Nobody took the question: the agent is not running.
    static let notRunning = "Omarchy's helper is not running. It starts once you are signed in to Omarchy's desktop: sign in there, then try again."
    /// Taken, and no answer: an agent from before this launcher, which takes every command and knows only its own.
    static let noAnswer = "Omarchy's helper took the question and did not answer. A helper from before launcher 0.7.61 learns Claude Install… when the machine starts again: choose Machine › Restart in its window, then open Claude Install… once more."

    /// Whether the agent took the command for `id` (it removes what it takes).
    private func taken(_ id: String) async -> Bool {
        await wait(takeTimeout) { FileManager.default.fileExists(atPath: ClaudeInstall.commandFile(self.share, id).path) ? nil : true } != nil
    }

    /// Where the wizard's files are: the machine's share, or for Windows the folder that stands in for one.
    var share: String { windows ? WindowsLink.folder(machine.machineFolder).path : machine.shareDir }
    private func prepare() -> String? {
        windows ? WindowsLink.Files(base: share, tool: "claude").prepare() : ClaudeInstall.prepare(share)
    }

    /// The first page: what is there.
    func check() {
        task?.cancel()
        page = .checking
        task = Task { [weak self] in
            guard let self else { return }
            if let problem = prepare() { page = .unreachable(problem); return }
            let id = ClaudeInstall.newID()
            guard ClaudeInstall.ask(share, "status", id) else { page = .unreachable("Could not leave the question for \(system) in \(ClaudeInstall.control(share).path)."); return }
            guard await taken(id) else {
                ClaudeInstall.forget(share, id)
                if !Task.isCancelled { page = .unreachable(notRunning) }
                return
            }
            let found = await wait(answerTimeout) { ClaudeInstall.status(self.share, id) }
            ClaudeInstall.forget(share, id)
            guard !Task.isCancelled else { return }
            guard let found else { page = .unreachable(noAnswer); return }
            status = found
            page = .status
        }
    }

    /// The form for a (further) subscription, with the names that are free.
    func openForm() {
        request = ClaudeRequest(alias: status.nextAlias, account: "", token: "", apiKey: "",
                                makeDefault: !status.defaultToken && !status.browserLogin)
        page = .form
    }

    /// Carry out `r` (nil: only what is missing, no token) and follow it.
    func run(_ r: ClaudeRequest?) {
        task?.cancel()
        let sent = r ?? ClaudeRequest()
        request.token = ""; request.apiKey = ""           // the fields forget them once they are on their way
        steps = []; outcome = nil
        page = .working
        task = Task { [weak self] in
            guard let self else { return }
            let id = ClaudeInstall.newID()
            if let problem = prepare() { failed(id, problem); return }
            guard ClaudeInstall.writeRequest(sent, id: id, share: share), ClaudeInstall.ask(share, "apply", id) else {
                failed(id, "Could not write the request into \(ClaudeInstall.folder(share).path)."); return
            }
            guard await taken(id) else { failed(id, notRunning); return }
            // the script takes the request first: gone means it has begun
            let begun = await wait(answerTimeout) { FileManager.default.fileExists(atPath: ClaudeInstall.requestFile(self.share, id).path) ? nil : true }
            guard begun != nil else { failed(id, noAnswer); return }
            // an install is a download of a few hundred megabytes: as long as that takes, within reason
            let done = await wait(setupTimeout) { () -> ClaudeOutcome? in
                let now = ClaudeInstall.steps(self.share, id)
                if now != self.steps { self.steps = now }
                return ClaudeInstall.outcome(self.share, id)
            }
            guard !Task.isCancelled else { ClaudeInstall.forget(share, id); return }
            ClaudeInstall.forget(share, id)
            guard let done else { failed(id, "The setup inside did not finish in \(Int(setupTimeout / 60)) minutes. It may still be going on there: ask again in a while."); return }
            steps = done.steps
            if let s = done.status { status = s }
            outcome = done
            page = .finished
        }
    }

    /// The setup could not be started or followed: told as a step of its own, after the ones that ran.
    private func failed(_ id: String, _ why: String) {
        ClaudeInstall.forget(share, id)
        outcome = ClaudeOutcome(ok: false, steps: steps + [ClaudeStep(["step": "machine", "title": "Reaching \(system)", "state": "failed", "detail": why])!],
                                alias: "", account: "", makeDefault: false, status: nil)
        page = .finished
    }

    /// The window closed: a setup that has begun goes on inside; a request the machine never took leaves the share
    /// once its minute is over.
    func close() {
        task?.cancel(); task = nil
        let share = share
        DispatchQueue.main.asyncAfter(deadline: .now() + ClaudeInstall.requestLifetime + 1) { ClaudeInstall.sweep(share) }
    }

    /// `probe` every 0.4 s until it has something, or nil after `seconds`.
    private func wait<T>(_ seconds: TimeInterval, _ probe: @MainActor () -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !Task.isCancelled {
            if let v = probe() { return v }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return Task.isCancelled ? nil : probe()
    }
}

/// The wizard: what is there, the token's form, the steps as they go, and how it ended. Every page has the same
/// size (see ClaudeInstallWindow): what a page shows scrolls when it is more than fits, and its buttons stay at the bottom.
struct ClaudeInstallView: View {
    @ObservedObject var model: ClaudeInstallModel
    let close: () -> Void
    static let size = CGSize(width: 560, height: 460)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 26)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code in \(model.machine.name)").font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            switch model.page {
            case .checking: checking
            case .unreachable(let why): unreachable(why)
            case .status: statusPage
            case .form: form
            case .working: working
            case .finished: finished
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private var subtitle: String {
        switch model.page {
        case .checking, .unreachable, .status: return "What is installed, who is signed in, and what the status line shows."
        case .form: return model.status.hasToken ? "Another subscription, as an alias of its own." : "Signed in with a long-lived token: no browser inside."
        case .working: return "Setting it up inside the machine."
        case .finished: return model.outcome?.ok == true ? "Done." : "Not everything went through."
        }
    }

    /// A page: what it shows, from the top, and below it what is said above the buttons and the buttons themselves.
    private func page<Content: View, Footer: View>(@ViewBuilder _ content: () -> Content, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.vertical) { content().frame(maxWidth: .infinity, alignment: .topLeading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer()
        }
    }

    // ---- 1. what is there ---------------------------------------------------------------------------------------------
    private var checking: some View {
        page {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking inside \(model.machine.name)…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } footer: {
            HStack { Spacer(); Button("Cancel") { close() }.keyboardShortcut(.cancelAction) }
        }
    }

    private func unreachable(_ why: String) -> some View {
        page {
            Label { Text(why).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
        } footer: {
            HStack {
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button("Try Again") { model.check() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private enum Mark { case good, missing, warn }
    private func row(_ mark: Mark, _ title: String, _ detail: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: mark == .good ? "checkmark.circle.fill" : mark == .warn ? "exclamationmark.triangle.fill" : "circle")
                .foregroundStyle(mark == .good ? Color.green : mark == .warn ? Color.orange : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }

    private var statusPage: some View {
        let s = model.status
        return page {
            VStack(alignment: .leading, spacing: 9) {
                if s.installed { row(.good, "Claude Code \(s.version.isEmpty ? "is installed" : s.version)", s.path) }
                else { row(.missing, "Claude Code is not installed") }
                if s.windows && !s.git && !s.installed { row(.missing, "Git for Windows is not installed", "Claude Code works through it: it is installed first.") }
                if s.windows {
                    if s.desktopInstalled { row(.good, "Claude, the desktop app\(s.desktopVersion.isEmpty ? "" : " \(s.desktopVersion)")", s.desktopPinned ? "On the taskbar." : "In the Start menu.") }
                    else { row(.missing, "Claude, the desktop app, is not installed") }
                }
                ForEach(s.accounts) { a in
                    if !a.token { row(.warn, "\(a.alias) has no token", "Add a subscription with this alias to give it one.") }
                    else if a.account.isEmpty { row(.warn, "\(a.alias): a subscription without a name", "The status line has no account to show for it; add it again with a name.") }
                    else { row(.good, "\(a.alias): \(a.account)", "Its own token: type \(a.alias) in a terminal to start Claude Code with it.") }
                }
                if s.defaultToken { row(.good, "claude and cc: \(s.defaultAccount.isEmpty ? "signed in with a token" : s.defaultAccount)", "The token every new terminal loads.") }
                else if s.browserLogin { row(.good, "claude and cc: signed in with the browser") }
                else if s.accounts.isEmpty { row(.missing, "Not signed in", "No token is saved here.") }
                else { row(.missing, "claude and cc: not signed in", "Only the aliases above have a token.") }
                if s.statusLineOK { row(.good, "The status line shows the account", "With the folder, git branch, context, limits, cost and model.") }
                else if s.lineScript && s.lineConfigured { row(.warn, "The status line does not show the account", "\(s.windows ? ".claude\\statusline.ps1" : "~/.claude/statusline.sh") is not myLinux's, or an older one.") }
                else if !s.lineCommand.isEmpty { row(.warn, "Another status line is set", s.lineCommand) }
                else { row(.missing, "No status line") }
                if !s.accounts.isEmpty {
                    if !s.aliasesMissing.isEmpty { row(.warn, "New terminals do not have \(s.aliasesMissing.joined(separator: ", "))") }
                    else if !s.aliasesLoaded { row(.warn, s.windows ? "New terminals do not find the aliases" : "New terminals do not load the aliases", s.windows ? ".local\\bin in your user folder, where they are, is not on your PATH." : "~/.bashrc lacks the line that reads them.") }
                }
            }
        } footer: {
            Divider()
            if !s.signedIn {
                Text((s.installed ? "Claude Code here has no token. The next page asks for one and sets up an alias and the status line with it."
                                  : "The next page asks for a Claude Code token, then installs Claude Code with an alias for the account and the status line.")
                     + (s.windows && !s.desktopInstalled ? " Claude, the desktop app, is installed with it and pinned to the taskbar (\(ClaudeStatus.taskbarNote))." : ""))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button("Continue") { model.openForm() }.keyboardShortcut(.defaultAction)
                }
            } else if s.repairs.isEmpty {
                Text("Everything is in place.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Add a Subscription…") { model.openForm() }
                    Spacer()
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.installed ? "Install or update this?" : "Install this?").font(.callout.weight(.medium))
                    ForEach(s.repairs, id: \.self) { r in
                        Text("•  " + r).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Add a Subscription…") { model.openForm() }
                    Spacer()
                    Button("Not Now") { close() }.keyboardShortcut(.cancelAction)
                    Button(s.installed && s.lineScript ? "Update" : "Install") { model.run(nil) }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    // ---- 2. the token ------------------------------------------------------------------------------------------------
    private var form: some View {
        let problem = model.request.problem(catalogAliases: model.catalogAliases)
        let replaces = model.status.accounts.contains { $0.alias == model.request.alias.trimmingCharacters(in: .whitespaces) }
        return page {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Claude Code token").gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            SecureField("sk-ant-oat01-…", text: $model.request.token).textFieldStyle(.roundedBorder)
                            Text("From claude setup-token, in a terminal where Claude Code is signed in (this Mac's, for instance). It is valid for about a year.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    GridRow {
                        Text("Account name")
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("viktor_gmail", text: $model.request.account).textFieldStyle(.roundedBorder)
                            Text("What the status line shows for this subscription.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Alias")
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("cc1", text: $model.request.alias).textFieldStyle(.roundedBorder).frame(width: 140)
                            Text(replaces ? "\(model.request.alias) is there already: it gets this token and name."
                                          : "Typed in a terminal inside, it starts Claude Code with this subscription.")
                                .font(.caption).foregroundStyle(replaces ? Color.orange : Color.secondary)
                        }
                    }
                    if !model.windows {                 // (your skills from mylinux.app come as a shell script: the Linux machines')
                        GridRow {
                            Text("myLinux API key")
                            VStack(alignment: .leading, spacing: 3) {
                                SecureField(model.status.apiKey ? "saved in this machine" : "mlx_…  (optional)", text: $model.request.apiKey).textFieldStyle(.roundedBorder)
                                Text("Optional: with it your skills, commands and CLAUDE.md from mylinux.app are installed too.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    GridRow {
                        Text("")
                        Toggle("Use it for plain claude and the alias cc too", isOn: $model.request.makeDefault)
                            .help(model.status.defaultToken ? "Replaces the token every new terminal loads now\(model.status.defaultAccount.isEmpty ? "" : " (\(model.status.defaultAccount))")."
                                                            : "Every new terminal loads this token, so claude and cc start signed in.")
                    }
                }
                Text(model.windows ? "The token goes to Windows through the machine's own channel, not through a shared folder, and is kept in your user folder there (.config\\mylinux\\claude-accounts), in a file only your account reads; it is not kept on the Mac."
                                   : "The token goes through the machine's share folder to ~/.config/mylinux/claude-accounts inside, in a file only you read there; it is not kept on the Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(1)                                 // the fields' focus ring is not cut off at the scroll view's edge
        } footer: {
            // one line, there from the start: a message that comes and goes would move the buttons
            Text(model.request.cleanToken.isEmpty ? " " : problem ?? " ").font(.caption).foregroundStyle(.red).lineLimit(1)
            HStack {
                Button("Back") { model.page = .status }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(model.status.installed ? "Set Up" : "Install") { model.run(model.request) }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
    }

    // ---- 3. the steps, and how it ended -----------------------------------------------------------------------------------
    private func stepRow(_ s: ClaudeStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch s.state {
                case "running": ProgressView().controlSize(.small).scaleEffect(0.7)
                case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                default: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }.frame(width: 18, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title)
                if !s.detail.isEmpty {
                    Text(s.detail).font(s.state == "failed" || s.state == "skipped" ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var working: some View {
        page {
            VStack(alignment: .leading, spacing: 9) {
                if model.steps.isEmpty { HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Starting inside \(model.machine.name)…").foregroundStyle(.secondary) } }
                ForEach(model.steps) { stepRow($0) }
            }
        } footer: {
            Text(model.windows ? "Installing Claude Code downloads it inside the machine, and Git for Windows before it when that is missing: a few minutes. Closing this window does not stop it."
                               : "Installing Claude Code downloads it inside the machine: about a minute. Closing this window does not stop it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Close") { close() }.keyboardShortcut(.cancelAction) }
        }
    }

    private var finished: some View {
        let o = model.outcome
        return page {
            VStack(alignment: .leading, spacing: 9) { ForEach(o?.steps ?? model.steps) { stepRow($0) } }
        } footer: {
            Divider()
            if let o, o.ok {
                Text(doneText(o)).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add Another Subscription…") { model.openForm() }
                    Spacer()
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("What is marked done stays; the rest can be tried again.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                    Button("Check Again") { model.check() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func doneText(_ o: ClaudeOutcome) -> String {
        guard !o.alias.isEmpty else { return "Claude Code in \(model.machine.name) is set up. A session that is open shows the status line within seconds; aliases are there in a new terminal." }
        return "Open a new terminal in \(model.machine.name) and type \(o.alias)\(o.makeDefault ? " (or cc, or claude)" : ""): Claude Code starts signed in, and its status line shows \(o.account)."
    }
}

/// The wizard in a window of its own, in front of the machine's.
enum ClaudeInstallWindow {
    private static var open: [UUID: (NSWindow, ClaudeInstallModel)] = [:]

    /// The wizard that is open for a machine (a test drives it).
    static func model(for id: UUID) -> ClaudeInstallModel? { open[id]?.1 }

    /// The wizard's window, one size for every page, set here and not by the view. A window that follows its page's
    /// height (.preferredContentSize) is resized from inside its own layout pass when the page changes; on a Retina
    /// display that ended the launcher on the first Continue (0.7.61: AppKit's "more Update Constraints in Window
    /// passes than there are views in the window", thrown as the hosting view answered the new frame).
    @MainActor static func window(_ model: ClaudeInstallModel, close: @escaping () -> Void) -> NSWindow {
        let hosting = NSHostingController(rootView: ClaudeInstallView(model: model, close: close))
        hosting.sizingOptions = []
        let w = NSWindow(contentViewController: hosting)
        w.title = "\(model.machine.name): Claude Install"
        w.styleMask = [.titled, .closable]
        w.setContentSize(ClaudeInstallView.size)
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        return w
    }

    @MainActor static func show(_ machine: Profile) {
        NSApp.activate()
        if let (w, _) = open[machine.id] { w.makeKeyAndOrderFront(nil); return }
        if let why = WindowsLink.notYet(machine) {
            let alert = NSAlert(); alert.messageText = "Claude Install in \(machine.name)"; alert.informativeText = why
            alert.runModal(); return
        }
        let model = ClaudeInstallModel(machine: machine)
        var made: NSWindow?
        let w = window(model, close: { made?.close() })
        made = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { open[machine.id]?.1.close(); open[machine.id] = nil }
        }
        open[machine.id] = (w, model)
        MachineWindowPlacement.place(w, for: machine)
        w.makeKeyAndOrderFront(nil)
        model.check()
    }
}
