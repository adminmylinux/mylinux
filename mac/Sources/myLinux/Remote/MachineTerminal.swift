import AppKit

/// What a terminal window needs from one terminal pane, whichever engine draws it: Ghostty (GhosttySshTerminal, the
/// default) or SwiftTerm (SshTerminal, the earlier one; Settings › Terminal). Both run the Mac's ssh with the same arguments.
@MainActor
protocol MachineTerminal: NSView {
    var onExit: ((Int32?) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    /// A link the user activated (⌘-click); when nil, links open in the default browser.
    var onOpenLink: ((URL) -> Void)? { get set }
    /// The view that takes the keyboard (the terminal itself, or the surface inside it).
    var keyView: NSView { get }
    func start()
    /// Types text into the session; a final newline presses Return.
    func type(_ text: String)
    /// The last http(s) URL on screen or in the scrollback.
    func lastURL() -> URL?
    /// Ends the ssh process (⌘W on one pane of several).
    func terminate()
}

/// Which engine draws the terminals: the setting, read when a pane is made.
enum TerminalEngine: String, CaseIterable {
    case ghostty, swiftTerm = "swiftterm"

    static let settingKey = "terminalEngine"
    static var current: TerminalEngine {
        if let e = ProcessInfo.processInfo.environment["MYLINUX_TERMINAL"].flatMap(TerminalEngine.init(rawValue:)) { return e }   // tests
        return UserDefaults.standard.string(forKey: settingKey).flatMap(TerminalEngine.init(rawValue:)) ?? .ghostty
    }
    var title: String { self == .swiftTerm ? "SwiftTerm (the earlier terminal)" : "Ghostty" }

    @MainActor static func make(profile: RemoteProfile) -> any MachineTerminal {
        switch current {
        case .swiftTerm: return SshTerminal(profile: profile)
        case .ghostty: return GhosttySshTerminal(profile: profile)
        }
    }
}

extension SshTerminal: MachineTerminal {
    var keyView: NSView { self }
}
