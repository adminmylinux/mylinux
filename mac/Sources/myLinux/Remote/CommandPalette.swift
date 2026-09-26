import SwiftUI
import AppKit

/// ⌘Space (SpaceHotkey, with the launcher's Accessibility permission) or ⌥Space in a server's terminal window, as
/// Super+Space in Omarchy: a search over
/// what can be run on the machine. Friendly names for the programs that are installed (type "cla", get Claude
/// Code), the Commands menu's entries, and every other program on the machine's PATH; Return types the command into
/// the terminal and runs it.
struct PaletteEntry: Identifiable, Equatable {
    enum Source: Int { case app, command, program }
    let title: String
    let detail: String
    let command: String
    var run = true
    let symbol: String
    let source: Source
    var id: String { "\(source.rawValue)|\(title)|\(command)" }
}

enum CommandPalette {
    /// Programs worth a name of their own, by the command that starts them.
    static let catalog: [(command: String, title: String, detail: String, symbol: String)] = [
        ("claude", "Claude Code", "Anthropic's coding agent", "sparkles"),
        ("codex", "Codex", "OpenAI's coding agent", "sparkles"),
        ("gemini", "Gemini CLI", "Google's coding agent", "sparkles"),
        ("opencode", "opencode", "An open coding agent", "sparkles"),
        ("btop", "btop", "Processes, CPU, memory, network", "gauge.with.dots.needle.33percent"),
        ("htop", "htop", "Processes", "gauge.with.dots.needle.33percent"),
        ("top", "top", "Processes", "gauge.with.dots.needle.33percent"),
        ("bun", "Bun", "JavaScript runtime and package manager", "shippingbox"),
        ("node", "Node.js", "JavaScript runtime", "shippingbox"),
        ("npm", "npm", "Node's package manager", "shippingbox"),
        ("python3", "Python", "Python 3", "chevron.left.forwardslash.chevron.right"),
        ("go", "Go", "The Go toolchain", "chevron.left.forwardslash.chevron.right"),
        ("cargo", "Cargo", "Rust's build tool", "chevron.left.forwardslash.chevron.right"),
        ("git", "Git", "Version control", "arrow.triangle.branch"),
        ("lazygit", "lazygit", "Git in the terminal", "arrow.triangle.branch"),
        ("gh", "GitHub CLI", "GitHub from the terminal", "arrow.triangle.branch"),
        ("tmux", "tmux", "Terminal sessions that outlive the window", "rectangle.split.3x1"),
        ("nvim", "Neovim", "Editor", "pencil"),
        ("vim", "Vim", "Editor", "pencil"),
        ("vi", "vi", "Editor", "pencil"),
        ("nano", "nano", "Simple editor", "pencil"),
        ("mc", "Midnight Commander", "Files, two panes", "folder"),
        ("ranger", "ranger", "Files", "folder"),
        ("yazi", "Yazi", "Files", "folder"),
        ("docker", "Docker", "Containers", "cube.box"),
        ("tailscale", "Tailscale", "Your private network", "network"),
        ("psql", "psql", "PostgreSQL client", "cylinder"),
        ("sqlite3", "SQLite", "SQLite shell", "cylinder"),
        ("fastfetch", "fastfetch", "This machine at a glance", "info.circle"),
        ("neofetch", "neofetch", "This machine at a glance", "info.circle"),
        ("chafa", "chafa", "Pictures in the terminal", "photo"),
    ]

    /// The entries for what the machine has: its installed programs (nil while still unknown), and the Commands menu.
    static func entries(programs: Set<String>?, alpine: Bool) -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        let known = Set(catalog.map(\.command))
        for app in catalog where programs?.contains(app.command) == true {
            out.append(PaletteEntry(title: app.title, detail: app.detail, command: app.command, symbol: app.symbol, source: .app))
        }
        for (section, list) in MachineCommands.sections(alpine: alpine) {
            for c in list where programs.map({ installed in needs(c.text).allSatisfy(installed.contains) }) ?? true {
                out.append(PaletteEntry(title: c.title, detail: section, command: c.text, run: c.run, symbol: "command", source: .command))
            }
        }
        for p in (programs ?? []).sorted() where !known.contains(p) {
            out.append(PaletteEntry(title: p, detail: "Program", command: p, symbol: "terminal", source: .program))
        }
        return out
    }

    /// The programs a Commands entry runs that are not always there: its aliases' programs (cc is Claude Code, cx
    /// Codex, from the install script), btop and tailscale. Such an entry shows once the machine is known to have them.
    static func needs(_ command: String) -> [String] {
        let words = command.split(separator: " ").map(String.init).filter { $0 != "sudo" && $0 != "doas" }
        switch words.first {
        case "cc": return ["claude"]
        case "cx": return ["codex"]
        case "btop", "tailscale": return [words[0]]
        default: return []
        }
    }

    /// The entries for a query, best first: names that start with it, then words that do, then names or commands
    /// containing it, then its letters in order. Plain programs show only once something is typed.
    static func search(_ query: String, in all: [PaletteEntry], limit: Int = 60) -> [PaletteEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all.filter { $0.source != .program } }
        var scored: [(Int, Int, PaletteEntry)] = []
        for (i, e) in all.enumerated() {
            let t = e.title.lowercased(), c = e.command.lowercased()
            let score: Int
            if t.hasPrefix(q) || c.hasPrefix(q) { score = 0 }
            else if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { score = 1 }
            else if t.contains(q) || c.contains(q) { score = 2 }
            else if subsequence(q, of: t) { score = 3 }
            else { continue }
            // among equals: named apps, then commands, then programs; a shorter program name first
            scored.append((score * 10 + e.source.rawValue, e.source == .program ? e.title.count : i, e))
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map(\.2)
    }

    /// Whether the query's letters appear in the text in order ("cc" in "Claude Code").
    static func subsequence(_ q: String, of s: String) -> Bool {
        var rest = Substring(s)
        for ch in q { guard let i = rest.firstIndex(of: ch) else { return false }; rest = rest[rest.index(after: i)...] }
        return true
    }

    /// The programs on the machine's PATH, the login shell's plus where the install scripts put things
    /// (~/.local/bin for Claude Code, ~/.bun/bin), read over the window's own ssh connection settings.
    static let listScript = #"for d in $(printf '%s' "$PATH:$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/usr/local/bin" | tr ':' ' '); do [ -d "$d" ] && ls -1 "$d" 2>/dev/null; done | sort -u"#

    static func loadPrograms(_ profile: RemoteProfile, done: @escaping (Set<String>?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4"] + SshTerminal.arguments(for: profile) + [listScript]
            let text = MachineStats.output("/usr/bin/ssh", args, timeout: 8)
            let names = text.map { Set($0.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") }) }
            DispatchQueue.main.async { done(names) }
        }
    }

    /// Per machine, what it had the last time: the palette shows it at once and refreshes behind.
    static var cache: [String: Set<String>] = [:]
}

final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { selected = 0 } }
    @Published var programs: Set<String>?
    @Published var selected = 0
    @Published var loading = true
    let alpine: Bool
    init(alpine: Bool, programs: Set<String>?) { self.alpine = alpine; self.programs = programs }
    var results: [PaletteEntry] { CommandPalette.search(query, in: CommandPalette.entries(programs: programs, alpine: alpine)) }
}

struct CommandPaletteView: View {
    @ObservedObject var model: PaletteModel
    let machine: String
    let pick: (PaletteEntry) -> Void
    let dismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Run on \(machine)… (claude, btop, update)", text: $model.query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { if results.indices.contains(model.selected) { pick(results[model.selected]) } }
                    .onKeyPress(.downArrow) { model.selected = min(model.selected + 1, max(0, results.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { model.selected = max(model.selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, e in
                            row(e, selected: i == model.selected).id(e.id)
                                .onTapGesture { pick(e) }
                        }
                        if results.isEmpty {
                            Text(model.loading ? "Looking at what is installed…" : "Nothing on \(machine) matches “\(model.query)”.")
                                .font(.callout).foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selected) { _, n in if results.indices.contains(n) { proxy.scrollTo(results[n].id) } }
            }
            Divider()
            HStack(spacing: 14) {
                Text("↩ run").font(.caption)
                Text("↑↓ choose").font(.caption)
                Text("esc close").font(.caption)
                Spacer()
                Text("⌘Space or ⌥Space").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7)
        }
        .frame(width: 560, height: 430)
        .onAppear { focused = true }
    }

    private func row(_ e: PaletteEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.symbol).frame(width: 20).foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).lineLimit(1)
                Text(e.detail).font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1)
            }
            Spacer()
            Text(e.command + (e.run ? "" : " …")).font(.caption.monospaced()).lineLimit(1)
                .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}
