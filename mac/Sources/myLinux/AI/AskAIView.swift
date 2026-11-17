import SwiftUI
import AppKit

/// The Ask AI… window (File › Ask AI…, ⌘J, the toolbar's sparkles), two tabs: Ask (the request, what the AI made of it,
/// the commands shown before anything runs, and their outcome) and Terminal (a bash on this Mac that starts the chosen
/// agent with the launcher's skill in place). Fixed in size: a hosted SwiftUI window that changes its own height has
/// crashed the launcher on a Retina display (0.7.61).
enum AskAIWindow {
    private static var window: NSWindow?
    /// `asking`: a request asked at once (the test hook MYLINUX_TEST_ASK_WINDOW).
    static func show(asking: String? = nil) {
        NSApp.activate()
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: AskAIView(asking: asking).frame(width: 720, height: 580)))
        w.title = "Ask AI"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 720, height: 580))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { AgentTerminalModel.current?.close() }       // the agent and its shell end with the window
            window = nil
        }
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class AskAIModel: ObservableObject {
    enum Step { case idle, thinking, plan, running, done }
    @Published var request = ""
    @Published var step = Step.idle
    @Published var say = ""
    @Published var commands: [[String]] = []         // as they run (defaults filled in)
    @Published var refused: [String] = []
    @Published var missing: [String] = []
    @Published var results: [(ok: Bool, text: String)] = []
    @Published var error: String?
    @Published var ready: (ok: Bool, text: String)?
    private var planned: [[String]] = []              // as the AI wrote them

    func checkProvider() { Task { ready = await AI.check(AI.provider) } }

    func ask() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, step != .thinking, step != .running else { return }
        step = .thinking; error = nil; say = ""; commands = []; refused = []; missing = []; results = []
        let system = AskAI.system(machines: ProfileStore.shared.profiles.map { CLIService.describe($0) },
                                  defaults: MachineDefaults.stored, hasPassword: MachineDefaults.password != nil)
        Task {
            do {
                let plan = try await AI.json(AskAI.Plan.self, system: system, user: text)
                say = plan.say ?? ""
                let c = AskAI.checked(plan)
                planned = c.commands; refused = c.refused
                fill()
                step = .plan
            } catch {
                self.error = error.localizedDescription; step = .idle
            }
        }
    }

    /// The stored defaults into the commands (again after the person has stored them).
    func fill() {
        let d = MachineDefaults.stored, pw = MachineDefaults.password
        var out: [[String]] = [], need: [String] = []
        for c in planned {
            let f = AskAI.filled(c, defaults: d, password: pw)
            out.append(f.argv); need += f.missing.filter { !need.contains($0) }
        }
        commands = out; missing = need
    }

    func run() {
        guard step == .plan, missing.isEmpty, !commands.isEmpty else { return }
        step = .running; results = []
        for c in commands {
            let o = AskAI.outcome(CLIService.handle(c))
            results.append(o)
            if !o.ok { break }                         // what follows may need what failed
        }
        step = .done
    }

    func reset() { step = .idle; say = ""; commands = []; refused = []; missing = []; results = []; error = nil }
}

/// The Terminal tab: one bash on this Mac at a time, kept while the window is open (switching tabs leaves it running).
@MainActor final class AgentTerminalModel: ObservableObject {
    static weak var current: AgentTerminalModel?
    @Published private(set) var terminal: GhosttySshTerminal?
    @Published var ended = false
    init() { AgentTerminalModel.current = self }

    func open() {
        guard terminal == nil else { return }
        let agent = AI.provider
        let exe = agent == .claude ? ClaudeCode.executable?.path : Codex.executable?.path
        // a folder of its own, not the home folder: the agent asks once whether to trust it, and its context is not all of ~
        let folder = Paths.support.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t = GhosttySshTerminal(localScript: AskAI.terminalScript(agent: agent, executable: exe, mylinux: CLI.Skill.command),
                                   directory: folder.path, title: agent.label)
        t.onExit = { [weak self, weak t] _ in guard let self, self.terminal === t else { return }; self.ended = true }
        t.start()
        terminal = t; ended = false
    }
    func again() { close(); open() }
    func close() { let t = terminal; terminal = nil; t?.terminate() }
}

/// The terminal in the SwiftUI tab, hidden (not torn down) while the Ask tab is in front.
struct AgentTerminalView: NSViewRepresentable {
    let terminal: GhosttySshTerminal
    let visible: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ box: NSView, context: Context) {
        if terminal.superview !== box {
            box.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = box.bounds; terminal.autoresizingMask = [.width, .height]
            box.addSubview(terminal)
        }
        box.isHidden = !visible
        if visible { DispatchQueue.main.async { box.window?.makeFirstResponder(terminal.keyView) } }
    }
}

struct AskAIView: View {
    var asking: String?
    @StateObject private var model = AskAIModel()
    @StateObject private var term = AgentTerminalModel()
    @AppStorage("ai.tab") private var tab = "ask"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $tab) { Text("Ask").tag("ask"); Text("Terminal").tag("terminal") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
            }
            provider
            ZStack(alignment: .topLeading) {
                askTab.opacity(tab == "ask" ? 1 : 0).allowsHitTesting(tab == "ask")
                if let t = term.terminal {
                    AgentTerminalView(terminal: t, visible: tab == "terminal")
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                        .opacity(tab == "terminal" ? 1 : 0)
                }
                if tab == "terminal" && term.ended {
                    VStack(spacing: 10) {
                        Text("The terminal ended.").foregroundStyle(.secondary)
                        Button("Open Again") { term.again() }.keyboardShortcut(.defaultAction)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(16)
        .onAppear {
            model.checkProvider()
            if tab == "terminal" { term.open() } else { focused = true }
            if let asking { tab = "ask"; model.request = asking; model.ask() }
        }
        .onChange(of: tab) { _, now in if now == "terminal" { term.open() } else { focused = true } }
    }

    private var askTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                TextField("Tell the launcher what to do: “Create omarchy machine 8/32 with username viktor and the rest as default”",
                          text: $model.request, axis: .vertical)
                    // three lines, the whole example in view: the bordered style keeps a field one line high
                    .lineLimit(3, reservesSpace: true).textFieldStyle(.plain).focused($focused)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: focused ? 2 : 1))
                    .onSubmit { model.ask() }
                Button(model.step == .thinking ? "Asking…" : "Ask") { model.ask() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.request.trimmingCharacters(in: .whitespaces).isEmpty || model.step == .thinking || model.step == .running || model.ready?.ok == false)
            }
            Divider()
            ScrollView { answer.frame(maxWidth: .infinity, alignment: .leading) }
            Spacer(minLength: 0)
        }
    }

    private var provider: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text(AI.provider.label).fontWeight(.semibold)
            if let r = model.ready {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.ok ? .green : .orange)
                Text(r.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Settings…") { VersionAndSettings.openSettings(page: "ai") }.controlSize(.small)
        }
    }

    @ViewBuilder private var answer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            switch model.step {
            case .idle:
                if model.error == nil {
                    Text("It can make, start, stop, restart and delete machines, and set up Claude Code or Codex in them: what the launcher's menus and its mylinux command do. You see the commands before anything runs.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .thinking:
                HStack { ProgressView().controlSize(.small); Text("Asking \(AI.provider.label)…").foregroundStyle(.secondary) }
            case .plan, .running, .done:
                if !model.say.isEmpty { Text(model.say).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if !model.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.commands.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if i < model.results.count {
                                    Image(systemName: model.results[i].ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                        .foregroundStyle(model.results[i].ok ? .green : .red)
                                } else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(AskAI.shown(model.commands[i])).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                    if i < model.results.count { Text(model.results[i].text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                if !model.refused.isEmpty {
                    Label("Left out (not something Ask AI does): " + model.refused.joined(separator: "; "), systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.step == .plan && !model.missing.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.missing.contains("defaults") ? "First, the defaults for a new machine: what it gets when you don't say. They are kept for next time (Settings › AI); the password in the Keychain."
                                                                : "A new machine needs a password: store one with the defaults (the password is kept in the Keychain).")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        DefaultsForm(saveTitle: "Save and Continue") { model.fill() }
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.6)))
                }
                HStack {
                    if model.step == .plan {
                        Button("Cancel") { model.reset() }
                        Button("Run") { model.run() }.keyboardShortcut(.defaultAction)
                            .disabled(!model.missing.isEmpty || model.commands.isEmpty)
                    } else if model.step == .done {
                        Button("New Request") { model.reset(); model.request = ""; focused = true }
                    }
                }
            }
        }
    }
}

/// The defaults for a new machine (Settings › AI, and Ask AI… when a request needs them first).
struct DefaultsForm: View {
    var saveTitle = "Save"
    var saved: () -> Void = {}
    @State private var d = MachineDefaults.stored ?? MachineDefaults.suggested
    @State private var password = ""
    @State private var hasPassword = MachineDefaults.password != nil
    @State private var note = ""

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow { Text("User name"); TextField("this Mac's (\(NSUserName()))", text: $d.user).textFieldStyle(.roundedBorder) }
            GridRow {
                Text("Password")
                SecureField(hasPassword ? "stored in the Keychain (type to change)" : "for the new machine's user and sudo", text: $password).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Keyboard")
                Picker("", selection: $d.keyboard) {
                    Text("As on this Mac").tag("")
                    ForEach(OmarchyUnattended.layouts.map(\.name), id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            GridRow { Text("Time zone"); TextField("this Mac's (\(TimeZone.current.identifier))", text: $d.timezone).textFieldStyle(.roundedBorder) }
            GridRow { Text("Full name"); TextField("optional", text: $d.fullName).textFieldStyle(.roundedBorder) }
            GridRow { Text("E-mail"); TextField("optional", text: $d.email).textFieldStyle(.roundedBorder) }
            GridRow {
                Text("")
                HStack {
                    Button(saveTitle) { save() }.disabled(!hasPassword && password.isEmpty)
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func save() {
        d.user = d.user.trimmingCharacters(in: .whitespaces); d.timezone = d.timezone.trimmingCharacters(in: .whitespaces)
        if !d.timezone.isEmpty, TimeZone(identifier: d.timezone) == nil { note = "“\(d.timezone)” is not a time zone (Europe/Oslo, Atlantic/Reykjavik …)"; return }
        if !password.isEmpty {
            guard MachineDefaults.setPassword(password) else { note = "The Keychain did not take the password"; return }
            password = ""; hasPassword = true
        }
        MachineDefaults.stored = d
        note = "Saved"
        saved()
    }
}
