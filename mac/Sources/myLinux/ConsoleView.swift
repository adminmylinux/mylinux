import SwiftUI
import AppKit

/// The guest's serial console: a root shell inside the running machine. Handy when the desktop is stuck, and it is
/// how Shut Down asks the guest to power off. Click the text and type, like a terminal: keys, Ctrl combinations and
/// pasted text go straight to the shell.
struct ConsoleView: View {
    @ObservedObject var runner: Runner
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Console").font(.headline)
                Circle().fill(runner.consoleConnected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(runner.consoleConnected ? (focused ? "root shell — typing goes to the machine" : "root shell — click to type")
                                             : "not connected")
                    .foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("Paste") { paste() }.disabled(!runner.consoleConnected)
                Button("Ctrl-C") { runner.send("\u{03}") }.disabled(!runner.consoleConnected)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.console.isEmpty ? "Waiting for the guest…" : runner.console + (focused ? "▏" : ""))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: runner.console) { _, _ in proxy.scrollTo("bottom") }
                .onAppear { proxy.scrollTo("bottom") }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onTapGesture { focused = true }
            .onKeyPress(phases: [.down, .repeat]) { press in
                guard runner.consoleConnected, let bytes = ConsoleView.bytes(for: press) else { return .ignored }
                runner.send(bytes)
                return .handled
            }
            .onPasteCommand(of: [.plainText]) { _ in paste() }
        }
        .onAppear { focused = runner.consoleConnected }
    }

    private func paste() {
        guard runner.consoleConnected, let text = NSPasteboard.general.string(forType: .string) else { return }
        runner.send(text.replacingOccurrences(of: "\r\n", with: "\n"))
        focused = true
    }

    /// What a terminal sends for a key: control characters for Ctrl combinations, VT100 sequences for arrows.
    static func bytes(for press: KeyPress) -> String? {
        if press.modifiers.contains(.command) { return nil }                 // ⌘ shortcuts stay with the app (⌘V pastes)
        switch press.key {
        case .return: return "\r"
        case .delete: return "\u{7f}"
        case .deleteForward: return "\u{1b}[3~"
        case .tab: return "\t"
        case .escape: return "\u{1b}"
        case .upArrow: return "\u{1b}[A"
        case .downArrow: return "\u{1b}[B"
        case .rightArrow: return "\u{1b}[C"
        case .leftArrow: return "\u{1b}[D"
        case .home: return "\u{1b}[H"
        case .end: return "\u{1b}[F"
        default: break
        }
        if press.modifiers.contains(.control) {
            // Ctrl+letter -> 0x01...0x1a; press.characters already holds the control character on macOS for most keys
            if let c = press.key.character.lowercased().unicodeScalars.first, c.value >= 97, c.value <= 122 {
                return String(UnicodeScalar(c.value - 96)!)
            }
        }
        let chars = press.characters
        return chars.isEmpty ? nil : chars
    }
}
