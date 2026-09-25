import AppKit
import GhosttyKit
import GhosttyTerminal

/// An SSH terminal drawn by Ghostty (GhosttyKit, the opt-in engine: Settings › Terminal): the same ssh command and
/// environment as SshTerminal, run by Ghostty itself, with Ghostty's Metal renderer, fonts and input. The window's
/// own keys (⌘↩, ⇧⌘↩, ⌘T, ⌘W, ⌘P) stay the window's: Ghostty's default key bindings are cleared and only copy,
/// paste, select all, clear and font size are bound again.
@MainActor
final class GhosttySshTerminal: NSView, MachineTerminal {
    let profile: RemoteProfile
    var onExit: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    private let surfaceView = AppTerminalView(frame: .zero)
    private var surface: TerminalSurface?
    private var exited = false

    /// One Ghostty app for every pane: the config below, applied once.
    static let controller = TerminalController { c in
        c.withCustom("term", "xterm-256color")            // the machines have no xterm-ghostty terminfo
        c.withCustom("shell-integration", "none")          // ssh, not a local shell
        c.withCustom("confirm-close-surface", "false")
        c.withCustom("abnormal-command-exit-runtime", "0")  // never hold a pane with Ghostty's "failed to launch" page
        c.withCustom("window-padding-balance", "true")
        c.withWindowPaddingX(6)
        c.withWindowPaddingY(4)
        c.withFontSize(13)
        c.withCustom("keybind", "clear")
        for bind in ["super+c=copy_to_clipboard", "super+v=paste_from_clipboard", "super+a=select_all",
                     "super+k=clear_screen", "super+equal=increase_font_size:1", "super+plus=increase_font_size:1",
                     "super+minus=decrease_font_size:1", "super+zero=reset_font_size",
                     "super+home=scroll_to_top", "super+end=scroll_to_bottom",
                     "shift+page_up=scroll_page_up", "shift+page_down=scroll_page_down"] {
            c.withCustom("keybind", bind)
        }
    }

    init(profile: RemoteProfile) {
        self.profile = profile
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.width, .height]
        addSubview(surfaceView)
    }
    required init?(coder: NSCoder) { fatalError() }

    var keyView: NSView { surfaceView }

    override func layout() {
        super.layout()
        surfaceView.frame = bounds
    }

    /// The command line for Ghostty, which on macOS runs it as `login -flp <user> bash -c "exec -l <command>"`:
    /// every argument single-quoted, and the program started through `env sh -c`, which first clears the screen and
    /// scrollback (login's "Last login: …" line on the Mac is not the machine's), runs it with the arguments exactly
    /// as given, and exits 0 whatever it returned: Ghostty takes a failing command for one that could not start
    /// and holds the pane with its own error ("Press any key") instead of closing it, and the window's
    /// "Disconnected — click to reconnect" and its reconnect after a restart hang on that close.
    nonisolated static func commandLine(_ executable: String, _ args: [String]) -> String {
        let wrapped = ["/usr/bin/env", "sh", "-c", #"printf '\033[H\033[2J\033[3J'; "$0" "$@"; exit 0"#, executable] + args
        return wrapped.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    func start() {
        var args = SshTerminal.arguments(for: profile)
        let tmux = profile.tmux.trimmingCharacters(in: .whitespaces)
        if !tmux.isEmpty { args.insert("-t", at: args.count - 1); args += ["tmux", "new-session", "-A", "-s", tmux] }
        var env: [String: String] = ["COLORTERM": "truecolor"]
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = agent }
        if profile.hasPassword {
            env["SSH_ASKPASS"] = SshTerminal.askpassScript.path
            env["SSH_ASKPASS_REQUIRE"] = "prefer"
            env["SSH_ASKPASS_ACCOUNT"] = RemoteSecrets.account(profile)
            env["DISPLAY"] = "myLinux"
        }
        var command = GhosttySshTerminal.commandLine("/usr/bin/ssh", args)
        // MYLINUX_LOCAL_SHELL=1: a local shell instead of ssh, for looking at the window without a machine
        if ProcessInfo.processInfo.environment["MYLINUX_LOCAL_SHELL"] == "1" {
            command = GhosttySshTerminal.commandLine("/bin/sh", ["-c", "printf 'Xabcdefghij first column check\\n0123456789 second line\\n'; exec /bin/sh -i"])
        }
        surfaceView.delegate = self
        surfaceView.configuration = TerminalSurfaceOptions(
            backend: .exec, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            envVars: env, command: command, waitAfterCommand: false)
        surfaceView.controller = GhosttySshTerminal.controller
    }

    func type(_ text: String) {
        var body = text
        let enter = body.hasSuffix("\n")
        if enter { body.removeLast() }
        // a paste (bracketed when the program asked for it), then Return as a key press
        if !body.isEmpty { _ = surfaceView.paste(text: body) }
        if enter { _ = surfaceView.sendKey(.enter) }
    }

    /// The whole screen and scrollback, read through Ghostty's C API (soft-wrapped rows come back joined).
    func screenText() -> String? {
        guard let s = surface?.rawValue else { return nil }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(s, sel, &out) else { return nil }
        defer { ghostty_surface_free_text(s, &out) }
        guard let p = out.text, out.text_len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(out.text_len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func lastURL() -> URL? {
        guard let text = screenText() else { return nil }
        return SshTerminal.lastURL(in: text, cols: Int.max)
    }

    var testHasSelection: Bool { surface?.hasSelection() ?? false }
    var testSelection: String? { surface?.readSelection() }

    func terminate() {
        guard !exited else { return }
        exited = true
        _ = surface?.performBindingAction("close_surface")
    }
}

extension GhosttySshTerminal: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate, TerminalSurfaceOpenURLDelegate,
                              TerminalSurfaceLifecycleDelegate {
    func terminalDidChangeTitle(_ title: String) { onTitle?(title) }

    func terminalDidClose(processAlive: Bool) {
        let wasExited = exited
        exited = true
        if !wasExited { onExit?(nil) }
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        guard let u = URL(string: url) else { return }
        if let handler = onOpenLink, ["http", "https"].contains(u.scheme ?? "") { handler(u); return }
        NSWorkspace.shared.open(u)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) { self.surface = surface }
    func terminalDidDetachSurface() { surface = nil }
}
