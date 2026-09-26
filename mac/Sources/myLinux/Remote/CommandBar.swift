import AppKit

/// A command the Commands menu types into the terminal: run at once, or left on the prompt to finish (a package name).
struct MachineCommand: Equatable {
    let title: String
    let text: String
    var run = true
}

/// The Commands menu of a server's terminal window, by distribution: Alpine (doas, apk, BusyBox) or Debian (sudo, apt).
enum MachineCommands {
    static func sections(alpine: Bool) -> [(String, [MachineCommand])] {
        let root = alpine ? "doas" : "sudo"
        return [
            ("Agents", [
                MachineCommand(title: "Claude Code  (cc)", text: "cc"),
                MachineCommand(title: "Codex  (cx)", text: "cx"),
            ]),
            ("This machine", [
                MachineCommand(title: "Processes  (btop)", text: "btop"),
                MachineCommand(title: "Disk space", text: "df -h"),
                MachineCommand(title: "Memory", text: "free -m"),
                MachineCommand(title: "Network addresses", text: "ip -br addr"),
                MachineCommand(title: "What is listening on which port", text: alpine ? "\(root) netstat -tlnp" : "\(root) ss -tlnp"),
            ]),
            ("Packages", [
                MachineCommand(title: "Update everything", text: alpine ? "doas apk update && doas apk upgrade" : "sudo apt update && sudo apt upgrade -y"),
                MachineCommand(title: "Install a package…", text: alpine ? "doas apk add " : "sudo apt install ", run: false),
                MachineCommand(title: "Search for a package…", text: alpine ? "apk search " : "apt search ", run: false),
            ]),
            ("Folders", [
                MachineCommand(title: "The Mac folder  (~/Mac)", text: "cd ~/Mac && ls"),
                MachineCommand(title: "Dropbox  (~/Dropbox)", text: "cd ~/Dropbox && ls"),
                MachineCommand(title: "Home", text: "cd && ls -la"),
            ]),
            ("Tailscale", [
                MachineCommand(title: "Sign in", text: "\(root) tailscale up"),
                MachineCommand(title: "Status", text: "tailscale status"),
            ]),
        ]
    }
}

/// The line at the top of a server's terminal window: the window's keys, and the Commands menu.
final class CommandBar: NSView {
    static let height: CGFloat = 26
    /// The window's keys, as the line shows them.
    static let keys: [(String, String)] = [("⌥Space", "find & run"), ("⌘↩", "split"), ("⇧⌘↩", "browser"), ("⌘T", "tab"),
                                           ("⌘W", "close pane"), ("⌘P", "menu"), ("⇧⌘P", "install"), ("⌘+ ⌘−", "text size"), ("⌘K", "clear")]
    private let label = NSTextField(labelWithString: "")
    private let menuButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var commands: [Int: MachineCommand] = [:]
    var onPick: ((MachineCommand) -> Void)?

    init(frame: NSRect, alpine: Bool) {
        super.init(frame: frame)
        let text = NSMutableAttributedString()
        for (i, (key, what)) in CommandBar.keys.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "    ")) }
            text.append(NSAttributedString(string: key, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            text.append(NSAttributedString(string: " " + what, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)

        menuButton.bezelStyle = .texturedRounded
        menuButton.controlSize = .small
        menuButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        menuButton.addItem(withTitle: "Commands")
        var tag = 1
        for (n, (section, list)) in MachineCommands.sections(alpine: alpine).enumerated() {
            if n > 0 { menuButton.menu?.addItem(.separator()) }
            menuButton.menu?.addItem(NSMenuItem.sectionHeader(title: section))
            for c in list {
                let item = NSMenuItem(title: c.title, action: #selector(picked(_:)), keyEquivalent: "")
                item.target = self; item.tag = tag; item.toolTip = c.text + (c.run ? "" : "  (then type the name)")
                menuButton.menu?.addItem(item)
                commands[tag] = c; tag += 1
            }
        }
        menuButton.toolTip = "Common commands, typed into the terminal"
        addSubview(menuButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let bw: CGFloat = 108, bh: CGFloat = 20
        menuButton.frame = NSRect(x: bounds.width - bw - 8, y: (bounds.height - bh) / 2, width: bw, height: bh)
        let lh = label.intrinsicContentSize.height
        label.frame = NSRect(x: 12, y: (bounds.height - lh) / 2, width: max(0, menuButton.frame.minX - 20), height: lh)
    }

    @objc private func picked(_ item: NSMenuItem) {
        if let c = commands[item.tag] { onPick?(c) }
    }

    /// For the tests: the commands the menu offers.
    var testCommands: [MachineCommand] { commands.keys.sorted().compactMap { commands[$0] } }
}
