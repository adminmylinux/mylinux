import AppKit

/// What a terminal window needs from one terminal pane (GhosttySshTerminal: Ghostty running the Mac's ssh).
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
