import AppKit
import SwiftUI

/// Codex Install… (in a Windows window's ⌘ menu): a wizard on the Mac that looks at Codex inside the machine and sets
/// it up. Its first page says what is there: Codex and its version, whether it is signed in, the alias cx, and whether
/// this Mac has a Codex login to give. What is missing it offers to put in place: Codex from winget (OpenAI's Arm64
/// build), cx (Codex without approvals or sandbox, as the Linux machines' cx), and the Mac's login.
///
/// Codex has no token to paste, as `claude setup-token` gives Claude Code. What OpenAI documents for a computer
/// without a browser is a copy of ~/.codex/auth.json from one that is signed in, and that is what "sign in with this
/// Mac's login" does (CodexLogin does the same for the Linux machines, asked from inside through the share). Windows
/// has a browser, so `codex` there can also sign in by itself: the copy is a choice on the page, said in full there,
/// and the button's name says when it is part of what is done.
///
/// The work inside is windows/claude_codex_setup.ps1 ("codex status", "codex apply"), reached as Claude Install
/// reaches it (WindowsLink). The login is in the link folder only until the helper has sent it on.
struct CodexStatus: Equatable {
    var installed = false, version = "", path = ""
    /// A login file is there and Codex takes it (`codex login status`); `loginFile` alone is a file Codex refuses.
    var signedIn = false, loginFile = false, says = ""
    var cx = false, onPath = false, winget = true

    static func parse(_ data: Data) -> CodexStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return CodexStatus(obj)
    }

    init() {}
    init?(_ obj: [String: Any]) {
        guard let codex = obj["codex"] as? [String: Any], let installed = codex["installed"] as? Bool else { return nil }
        self.installed = installed
        version = codex["version"] as? String ?? ""; path = codex["path"] as? String ?? ""
        let login = obj["login"] as? [String: Any] ?? [:]
        loginFile = login["file"] as? Bool ?? false; signedIn = loginFile && (login["accepted"] as? Bool ?? true); says = login["says"] as? String ?? ""
        let alias = obj["alias"] as? [String: Any] ?? [:]
        cx = alias["cx"] as? Bool ?? false; onPath = alias["loaded"] as? Bool ?? false
        winget = obj["winget"] as? Bool ?? true
    }

    /// What Install does without the login, in the wizard's words.
    var repairs: [String] {
        var out: [String] = []
        if !installed { out.append("Install Codex (OpenAI's Arm64 build, from winget)") }
        if !cx { out.append("Add the alias cx: Codex without approvals or sandbox") }
        else if !onPath { out.append("Put the alias's folder (.local\\bin in your user folder) on your PATH") }
        return out
    }
}

struct CodexOutcome: Equatable {
    var ok: Bool, steps: [ClaudeStep], status: CodexStatus?

    static func parse(_ data: Data) -> CodexOutcome? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ok = obj["ok"] as? Bool else { return nil }
        return CodexOutcome(ok: ok, steps: (obj["steps"] as? [[String: Any]] ?? []).compactMap(ClaudeStep.init),
                            status: (obj["status"] as? [String: Any]).flatMap(CodexStatus.init))
    }
}

enum CodexInstall {
    /// What the wizard asks the script to do: Codex and cx when they are missing, and the Mac's login when given.
    static func request(login: Data?) -> [String: Any] {
        ["install": true, "alias": true, "login": login.flatMap { String(data: $0, encoding: .utf8) } ?? ""]
    }

    /// This Mac's Codex login file (a test names another: MYLINUX_TEST_CODEX_LOGIN).
    static var macLogin: URL {
        ProcessInfo.processInfo.environment["MYLINUX_TEST_CODEX_LOGIN"].map { URL(fileURLWithPath: $0) } ?? CodexLogin.macLogin
    }
}

/// The wizard's state and its talk with the machine.
@MainActor final class CodexInstallModel: ObservableObject {
    enum Page: Equatable { case checking, unreachable(String), status, working, finished }

    let machine: Profile
    @Published var page: Page = .checking
    @Published var status = CodexStatus()
    @Published var steps: [ClaudeStep] = []
    @Published var outcome: CodexOutcome?
    /// The Mac has a login to give (looked at when the page is made, not read until it is sent).
    @Published var macHasLogin = false
    @Published var copyLogin = false
    private var task: Task<Void, Never>?
    var answerTimeout: TimeInterval = 45
    var takeTimeout: TimeInterval { min(12, answerTimeout) }

    init(machine: Profile) { self.machine = machine }

    var files: WindowsLink.Files { WindowsLink.Files(base: WindowsLink.folder(machine.machineFolder).path, tool: "codex") }

    private func taken(_ id: String) async -> Bool {
        await wait(takeTimeout) { FileManager.default.fileExists(atPath: self.files.commandFile(id).path) ? nil : true } != nil
    }

    /// The first page: what is there.
    func check() {
        task?.cancel()
        page = .checking
        task = Task { [weak self] in
            guard let self else { return }
            let files = files
            if let problem = files.prepare() { page = .unreachable(problem); return }
            let id = ClaudeInstall.newID()
            guard files.ask("status", id) else { page = .unreachable("Could not leave the question for Windows in \(files.control.path)."); return }
            guard await taken(id) else {
                files.forget(id)
                if !Task.isCancelled { page = .unreachable(ClaudeInstallModel.windowsNotRunning) }
                return
            }
            let found = await wait(answerTimeout) { (try? Data(contentsOf: files.statusFile(id))).flatMap(CodexStatus.parse) }
            files.forget(id)
            guard !Task.isCancelled else { return }
            guard let found else { page = .unreachable(ClaudeInstallModel.windowsNoAnswer); return }
            status = found
            macHasLogin = CodexLogin.login(at: CodexInstall.macLogin) != nil
            copyLogin = macHasLogin && !found.signedIn
            page = .status
        }
    }

    /// Whether there is anything to do with the choices as they are.
    var nothingToDo: Bool { status.repairs.isEmpty && !(copyLogin && macHasLogin) }

    /// Carry it out and follow it.
    func run() {
        task?.cancel()
        let login = copyLogin && macHasLogin ? CodexLogin.login(at: CodexInstall.macLogin) : nil
        steps = []; outcome = nil
        page = .working
        task = Task { [weak self] in
            guard let self else { return }
            let files = files
            let id = ClaudeInstall.newID()
            if let problem = files.prepare() { failed(id, problem); return }
            guard files.writeRequest(CodexInstall.request(login: login), id: id), files.ask("apply", id) else {
                failed(id, "Could not write the request into \(files.folder.path)."); return
            }
            guard await taken(id) else { failed(id, ClaudeInstallModel.windowsNotRunning); return }
            let done = await wait(30 * 60) { () -> CodexOutcome? in
                let now = ClaudeStep.parse(lines: (try? String(contentsOf: files.progressFile(id), encoding: .utf8)) ?? "")
                if now != self.steps { self.steps = now }
                return (try? Data(contentsOf: files.resultFile(id))).flatMap(CodexOutcome.parse)
            }
            files.forget(id)
            guard !Task.isCancelled else { return }
            guard let done else { failed(id, "The setup inside did not finish in half an hour."); return }
            steps = done.steps
            if let s = done.status { status = s }
            outcome = done
            page = .finished
        }
    }

    private func failed(_ id: String, _ why: String) {
        files.forget(id)
        outcome = CodexOutcome(ok: false, steps: steps + [ClaudeStep(["step": "machine", "title": "Reaching Windows", "state": "failed", "detail": why])!], status: nil)
        page = .finished
    }

    /// The window closed: a setup that has begun goes on inside; a request the machine never took (the login may be in
    /// it) leaves the link folder now.
    func close() {
        task?.cancel(); task = nil
        let files = files
        for url in (try? FileManager.default.contentsOfDirectory(at: files.folder, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("request-") || url.lastPathComponent.hasPrefix(".request-") { try? FileManager.default.removeItem(at: url) }
    }

    private func wait<T>(_ seconds: TimeInterval, _ probe: @MainActor () -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !Task.isCancelled {
            if let v = probe() { return v }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return Task.isCancelled ? nil : probe()
    }
}

/// The wizard: what is there and what is offered, the steps as they go, and how it ended. One size for every page (see
/// ClaudeInstallWindow for why).
struct CodexInstallView: View {
    @ObservedObject var model: CodexInstallModel
    let close: () -> Void
    static let size = CGSize(width: 560, height: 460)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 24)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex in \(model.machine.name)").font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            switch model.page {
            case .checking: checking
            case .unreachable(let why): unreachable(why)
            case .status: statusPage
            case .working: working
            case .finished: finished
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private var subtitle: String {
        switch model.page {
        case .checking, .unreachable, .status: return "What is installed, and who is signed in."
        case .working: return "Setting it up inside the machine."
        case .finished: return model.outcome?.ok == true ? "Done." : "Not everything went through."
        }
    }

    private func page<Content: View, Footer: View>(@ViewBuilder _ content: () -> Content, @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.vertical) { content().frame(maxWidth: .infinity, alignment: .topLeading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer()
        }
    }

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

    /// The button's name says what it does, the login among it.
    private var actionTitle: String {
        let login = model.copyLogin && model.macHasLogin
        if !model.status.installed { return login ? "Install and Sign In" : "Install" }
        if model.status.repairs.isEmpty { return "Sign In" }
        return login ? "Set Up and Sign In" : "Set Up"
    }

    private var statusPage: some View {
        let s = model.status
        return page {
            VStack(alignment: .leading, spacing: 9) {
                if s.installed { row(.good, "Codex \(s.version.isEmpty ? "is installed" : s.version)", s.path) }
                else if s.winget { row(.missing, "Codex is not installed") }
                else { row(.warn, "Codex is not installed, and winget is not there to install it", "Open Microsoft Store in Windows once and let App Installer update, then check again.") }
                if s.signedIn { row(.good, s.says.isEmpty ? "Signed in" : s.says, "Its login is in .codex\\auth.json in your user folder there.") }
                else if s.loginFile { row(.warn, "A login is there, and Codex does not take it", s.says) }
                else { row(.missing, "Not signed in", "Typing codex in a terminal there signs in through Windows's browser; or use this Mac's login, below.") }
                if s.cx && s.onPath { row(.good, "cx: Codex without approvals or sandbox") }
                else if s.cx { row(.warn, "New terminals do not find cx", ".local\\bin in your user folder, where it is, is not on your PATH.") }
                else { row(.missing, "No alias cx") }
                if model.macHasLogin { row(.good, "This Mac has a Codex login", "~/.codex/auth.json") }
                else { row(.missing, "This Mac has no Codex login file", "~/.codex/auth.json is not there. Sign in on the Mac first (codex login); if Codex keeps its login in the Keychain, set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml and sign in again.") }
            }
        } footer: {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(s.repairs, id: \.self) { r in
                    Text("•  " + r).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.macHasLogin {
                    Toggle(s.signedIn ? "Replace the login there with this Mac's" : "Sign Codex in with this Mac's login", isOn: $model.copyLogin)
                    Text("Copies ~/.codex/auth.json, your Codex login, into \(model.machine.name): Codex there runs as you, on your ChatGPT plan, and whatever runs in that machine can read the login.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(model.nothingToDo ? "Done" : "Not Now") { close() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { model.run() }.keyboardShortcut(.defaultAction).disabled(model.nothingToDo)
            }
        }
    }

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
            Text("Installing Codex downloads it inside the machine: a minute or two. Closing this window does not stop it.")
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
                Text("Open a new terminal in \(model.machine.name) and type cx (or codex)\(model.status.signedIn ? ": Codex starts signed in." : "; Codex asks you to sign in the first time.")")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { close() }.keyboardShortcut(.defaultAction) }
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
}

/// The wizard in a window of its own, in front of the machine's.
enum CodexInstallWindow {
    private static var open: [UUID: (NSWindow, CodexInstallModel)] = [:]

    /// The wizard that is open for a machine (a test drives it).
    static func model(for id: UUID) -> CodexInstallModel? { open[id]?.1 }

    @MainActor static func show(_ machine: Profile) {
        NSApp.activate()
        if let (w, _) = open[machine.id] { w.makeKeyAndOrderFront(nil); return }
        if let why = WindowsLink.notYet(machine) {
            let alert = NSAlert(); alert.messageText = "Codex Install in \(machine.name)"; alert.informativeText = why
            alert.runModal(); return
        }
        let model = CodexInstallModel(machine: machine)
        var made: NSWindow?
        let hosting = NSHostingController(rootView: CodexInstallView(model: model, close: { made?.close() }))
        hosting.sizingOptions = []
        let w = NSWindow(contentViewController: hosting)
        w.title = "\(machine.name): Codex Install"
        w.styleMask = [.titled, .closable]
        w.setContentSize(CodexInstallView.size)
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
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
