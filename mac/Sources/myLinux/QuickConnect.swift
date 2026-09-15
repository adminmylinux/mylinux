import AppKit

/// ⌘K: a floating field over everything. Type part of a machine's name or host, ↑↓ pick, Return opens it (a remote
/// desktop or terminal) or starts it (a myLinux machine); Escape closes. Also in the menu bar item.
final class QuickConnect: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = QuickConnect()

    struct Item: Equatable {
        let title: String, subtitle: String, symbol: String
        let remote: RemoteProfile?, machine: Profile?
        var searchText: String { (title + " " + subtitle).lowercased() }
    }

    /// The machines in the sidebar's order: myLinux machines, then remote ones.
    static func items(remote: [RemoteProfile], machines: [Profile]) -> [Item] {
        machines.map { Item(title: $0.name, subtitle: "myLinux machine", symbol: "desktopcomputer", remote: nil, machine: $0) }
        + remote.map { Item(title: $0.title, subtitle: ($0.kind == .ssh ? "ssh " : "vnc ") + $0.host + ":" + String($0.port) + ($0.username.isEmpty ? "" : " · " + $0.username),
                           symbol: $0.kind == .ssh ? "terminal" : "display", remote: $0, machine: nil) }
    }
    /// Every word of the query must appear in the title or subtitle; an empty query lists everything.
    static func filter(_ items: [Item], _ query: String) -> [Item] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { it in words.allSatisfy { it.searchText.contains($0) } }
    }

    private var panel: NSPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private var rows: [Item] = []

    func show() {
        if panel == nil { build() }
        rows = QuickConnect.filter(QuickConnect.items(remote: RemoteStore.shared.profiles, machines: ProfileStore.shared.profiles), "")
        field.stringValue = ""
        table.reloadData(); select(0)
        NSApp.activate(ignoringOtherApps: true)
        panel?.center(); panel?.makeKeyAndOrderFront(nil); panel?.makeFirstResponder(field)
    }

    private func build() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = "Quick Connect"; p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = true; p.isReleasedWhenClosed = false
        let root = NSView(frame: p.contentView!.bounds); root.autoresizingMask = [.width, .height]
        field.placeholderString = "Machine name or host — Return connects, Escape closes"
        field.font = NSFont.systemFont(ofSize: 18); field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = self
        // below the (transparent) title bar, clear of the close button
        field.frame = NSRect(x: 16, y: root.bounds.height - 66, width: root.bounds.width - 32, height: 28); field.autoresizingMask = [.width, .minYMargin]
        root.addSubview(field)
        let line = NSBox(frame: NSRect(x: 0, y: root.bounds.height - 74, width: root.bounds.width, height: 1)); line.boxType = .separator; line.autoresizingMask = [.width, .minYMargin]
        root.addSubview(line)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("machine")); col.width = root.bounds.width
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 36; table.style = .inset
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(pick)
        table.selectionHighlightStyle = .regular; table.refusesFirstResponder = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: root.bounds.width, height: root.bounds.height - 76)); scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        root.addSubview(scroll)
        p.contentView = root
        panel = p
    }

    // ---- the field: filtering, arrows, Return, Escape ----
    func controlTextDidChange(_ n: Notification) {
        rows = QuickConnect.filter(QuickConnect.items(remote: RemoteStore.shared.profiles, machines: ProfileStore.shared.profiles), field.stringValue)
        table.reloadData(); select(0)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1); return true
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(); return true
        case #selector(NSResponder.cancelOperation(_:)): panel?.close(); return true
        default: return false
        }
    }
    private func select(_ row: Int) {
        guard !rows.isEmpty else { table.deselectAll(nil); return }
        let r = min(max(row, 0), rows.count - 1)
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false); table.scrollRowToVisible(r)
    }

    @objc private func pick() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let it = rows[table.selectedRow]
        panel?.close()
        if let r = it.remote { RemoteWindowController.show(r) }
        if let m = it.machine { QuickStart.start(m) }
    }

    // ---- the list ----
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let it = rows[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 36))
        let icon = NSImageView(image: NSImage(systemSymbolName: it.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.frame = NSRect(x: 8, y: 9, width: 18, height: 18); icon.contentTintColor = .secondaryLabelColor
        let text = NSMutableAttributedString(string: it.title, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "   " + it.subtitle, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        let label = NSTextField(labelWithAttributedString: text)
        label.frame = NSRect(x: 34, y: 8, width: tableView.bounds.width - 44, height: 20); label.autoresizingMask = [.width]; label.lineBreakMode = .byTruncatingTail
        cell.addSubview(icon); cell.addSubview(label); cell.textField = label
        return cell
    }
}
