import AppKit
import SwiftUI

/// Snippets…: short commands for a machine's system (Omarchy, Debian, Alpine, myLinux), each with a name and a line
/// about it; View shows it, Copy puts it on the clipboard (shared with the machine) to paste into its terminal. The
/// built-in ones are server-apps/snippets.json, fetched from the repository's main branch (the copy inside the app
/// when GitHub cannot be reached), so a new one reaches every launcher; the user's own (+) are kept in the launcher's
/// snippets.json, per system. A VNC desktop's (its CMD menu) are a set of their own: snippets-vnc.json, built in and
/// the user's, which began as a copy of Omarchy's.
struct Snippet: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var description: String
    var os: [String]            // Profile.Kind raw values
    var text: String
    var own: Bool? = nil        // the user's (kept by the launcher), not built in

    var isOwn: Bool { own == true }
}

/// Which snippets: the system they are for (a Profile.Kind's raw value, or "vnc"), the file they are kept in (in
/// server-apps for the built-in ones, in the launcher's folder for the user's), and where a copied one is pasted.
struct SnippetSet: Hashable {
    let os: String
    let file: String
    let pasteHint: String

    static func machine(_ kind: Profile.Kind) -> SnippetSet { SnippetSet(os: kind.rawValue, file: "snippets.json", pasteHint: Snippets.pasteHint(kind)) }
    static let vnc = SnippetSet(os: "vnc", file: "snippets-vnc.json",
                                pasteHint: "paste it into a terminal on the remote (Ctrl+Shift+V in Omarchy); the clipboard goes over when its window is in front")
}

enum Snippets {
    static func url(_ file: String) -> URL { URL(string: "https://raw.githubusercontent.com/adminmylinux/mylinux/main/server-apps/\(file)")! }
    static func ownFile(_ file: String) -> URL { Paths.support.appendingPathComponent(file) }

    private struct File: Decodable { let snippets: [Snippet] }

    static func decode(_ data: Data) -> [Snippet]? { (try? JSONDecoder().decode(File.self, from: data))?.snippets }

    /// The built-in ones: GitHub's main, else the app's copy (or the checkout's, from a build).
    static func builtIn(_ file: String = "snippets.json") async -> [Snippet] {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 6
        if let (data, r) = try? await URLSession(configuration: config).data(from: url(file)), (r as? HTTPURLResponse)?.statusCode == 200,
           let list = decode(data) { return list }
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("server-apps"),
                    Paths.buildRepo.map { URL(fileURLWithPath: $0).appendingPathComponent("server-apps") }]
        for case let dir? in dirs {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(file)), let list = decode(data) { return list }
        }
        return []
    }

    static func own(_ file: String = "snippets.json") -> [Snippet] {
        guard let data = try? Data(contentsOf: ownFile(file)), let list = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
        return list.map { var s = $0; s.own = true; return s }
    }

    static func saveOwn(_ list: [Snippet], _ file: String = "snippets.json") throws {
        try FileManager.default.createDirectory(at: ownFile(file).deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(list).write(to: ownFile(file), options: .atomic)
    }

    /// Where a copied snippet goes, in words, for the machine's kind: "paste it into …".
    static func pasteHint(_ kind: Profile.Kind) -> String {
        switch kind {
        case .omarchy: return "paste it into a terminal in Omarchy with Ctrl+Shift+V"
        case .mylinux: return "paste it into a terminal in myLinux"
        case .debian, .alpine: return "paste it into the terminal with ⌘V"
        }
    }
}

@MainActor
final class SnippetsModel: ObservableObject {
    let set: SnippetSet
    @Published var builtIn: [Snippet] = []
    @Published var own: [Snippet] = []
    @Published var loading = true
    @Published var error = ""

    init(_ set: SnippetSet) { self.set = set }

    var shown: [Snippet] { (builtIn + own).filter { $0.os.contains(set.os) } }

    func load() {
        own = Snippets.own(set.file)
        Task { builtIn = await Snippets.builtIn(set.file); loading = false }
    }

    func save(_ s: Snippet) {
        var all = Snippets.own(set.file)
        if let i = all.firstIndex(where: { $0.id == s.id }) { all[i] = s } else { all.append(s) }
        persist(all)
    }

    func delete(_ s: Snippet) { persist(Snippets.own(set.file).filter { $0.id != s.id }) }

    private func persist(_ all: [Snippet]) {
        do { try Snippets.saveOwn(all.map { var s = $0; s.own = nil; return s }, set.file); own = Snippets.own(set.file); error = "" }
        catch { self.error = "Could not save your snippets: \(error.localizedDescription)" }
    }
}

struct SnippetsView: View {
    let machine: String
    @StateObject var model: SnippetsModel
    /// Paste: the text into the machine (its terminal when one is in front), nil when done or what went wrong
    var paste: ((String) async -> String?)? = nil
    @State private var pasted: String?
    @State private var viewing: Snippet?
    @State private var editing: Snippet?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snippets for \(machine)").font(.title3.weight(.semibold))
                    Text(paste != nil ? "Paste puts one into the terminal in front in \(machine), waiting for Return; or Copy, then \(model.set.pasteHint)." : "Copy one, then \(model.set.pasteHint).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = Snippet(id: UUID().uuidString, name: "", description: "", os: [model.set.os], text: "", own: true) } label: {
                    Image(systemName: "plus")
                }
                .help("A snippet of your own, for \(machine)")
            }
            if model.loading && model.shown.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if model.shown.isEmpty {
                Text("No snippets for this system yet; + adds one of your own.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Table(model.shown) {
                    TableColumn("Name") { s in
                        HStack(spacing: 6) {
                            if s.isOwn { Image(systemName: "person.crop.circle").foregroundStyle(.secondary).help("Yours") }
                            Text(s.name).fontWeight(.medium)
                        }
                    }.width(min: 150, ideal: 220, max: 260)
                    TableColumn("Description") { s in
                        Text(s.description).foregroundStyle(.secondary).lineLimit(2).help(s.description)
                    }
                    TableColumn("") { s in
                        HStack(spacing: 8) {
                            Button { viewing = s } label: { Image(systemName: "eye") }.help("View")
                            Button { copy(s) } label: { Image(systemName: copied == s.id ? "checkmark" : "doc.on.doc") }.help("Copy")
                            if paste != nil {
                                Button { doPaste(s) } label: { Image(systemName: pasted == s.id ? "checkmark" : "text.insert") }
                                    .help("Paste into \(machine): into its terminal when one is in front (Return runs it)")
                            }
                        }
                        .buttonStyle(.borderless)
                    }.width(paste == nil ? 56 : 84)
                }
            }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 380)
        .onAppear { model.load() }
        .sheet(item: $viewing) { s in
            SnippetDetail(snippet: s, hint: model.set.pasteHint, copy: { copy(s) },
                          edit: s.isOwn ? { viewing = nil; DispatchQueue.main.async { editing = s } } : nil,
                          delete: s.isOwn ? { model.delete(s); viewing = nil } : nil,
                          close: { viewing = nil })
        }
        .sheet(item: $editing) { s in
            SnippetEditor(snippet: s, system: machine, save: { model.save($0); editing = nil }, cancel: { editing = nil })
        }
    }

    private func doPaste(_ s: Snippet) {
        guard let paste else { return }
        // without the last newline: the command waits at the prompt for Return
        var text = s.text; while text.hasSuffix("\n") { text.removeLast() }
        Task {
            if let problem = await paste(text) { model.error = problem; return }
            model.error = ""; pasted = s.id
            try? await Task.sleep(nanoseconds: 1_500_000_000); if pasted == s.id { pasted = nil }
        }
    }

    private func copy(_ s: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.text.hasSuffix("\n") ? s.text : s.text + "\n", forType: .string)
        copied = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == s.id { copied = nil } }
    }
}

private struct SnippetDetail: View {
    let snippet: Snippet
    let hint: String
    let copy: () -> Void
    let edit: (() -> Void)?
    let delete: (() -> Void)?
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snippet.name).font(.title3.weight(.semibold))
            Text(snippet.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(snippet.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            Text("Copy, then \(hint).").font(.caption).foregroundStyle(.secondary)
            HStack {
                if let delete { Button("Delete", role: .destructive, action: delete) }
                if let edit { Button("Edit", action: edit) }
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button { copy(); copied = true } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620)
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    let system: String
    let save: (Snippet) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snippet.name.isEmpty ? "A snippet for \(system)" : "Edit \(snippet.name)").font(.title3.weight(.semibold))
            TextField("Name, e.g. Restart Waybar", text: $snippet.name).textFieldStyle(.roundedBorder)
            TextField("What it does", text: $snippet.description).textFieldStyle(.roundedBorder)
            TextEditor(text: $snippet.text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            Text("Kept by the launcher on this Mac, for \(system).").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(snippet) }.keyboardShortcut(.defaultAction)
                    .disabled(snippet.name.trimmingCharacters(in: .whitespaces).isEmpty || snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

/// The snippets of a machine's system in a window of its own, in front of the machine's window.
@MainActor
enum SnippetsWindow {
    private static var open: [UUID: NSWindow] = [:]

    /// `paste` types a snippet into the machine; without one, a desktop's (Omarchy's window, run by the launcher) is
    /// pasted through QEMU: the clipboard, then Ctrl+Shift+V.
    static func show(_ machine: Profile, over parent: NSWindow? = nil, paste: ((String) async -> String?)? = nil) {
        show(id: machine.id, name: machine.name, set: .machine(machine.kind), over: parent, machine: machine,
             paste: paste ?? (machine.kind == .omarchy && !MachineApp.active ? { await pasteIntoDesktop($0, machine) } : nil))
    }
    /// A VNC desktop's snippets (its CMD menu), over its window.
    static func show(remote: RemoteProfile, over parent: NSWindow?, paste: ((String) async -> String?)?) {
        show(id: remote.id, name: remote.title, set: .vnc, over: parent, machine: nil, paste: paste)
    }

    /// Omarchy's window: the text on the clipboard (QEMU hands it to Omarchy), then Ctrl+Shift+V into the window in
    /// front inside (a terminal pastes it), and Omarchy's window in front.
    static func pasteIntoDesktop(_ text: String, _ machine: Profile) async -> String? {
        let r = RunManager.shared.runner(for: machine.id)
        guard r.isActive, FileManager.default.fileExists(atPath: r.qmpSocket) else { return "\(machine.name) is not running in this launcher." }
        guard machine.clipboard else { return "Paste goes through the shared clipboard, which is off for \(machine.name) (its settings)." }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        // QEMU looks at the Mac's clipboard as it redraws; give it a moment to offer the text inside
        try? await Task.sleep(nanoseconds: 800_000_000)
        let path = r.qmpSocket
        let keys = #"{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ctrl"},{"type":"qcode","data":"shift"},{"type":"qcode","data":"v"}]}}"#
        let ok = await Task.detached { Runner.qmp(path, json: keys) }.value
        guard ok else { return "Could not reach \(machine.name)'s QEMU to paste; Copy, then Ctrl+Shift+V in its terminal." }
        if let pid = r.qemuPID { NSRunningApplication(processIdentifier: pid)?.activate() }
        return nil
    }

    private static func show(id: UUID, name: String, set: SnippetSet, over parent: NSWindow?, machine: Profile?, paste: ((String) async -> String?)?) {
        NSApp.activate()
        if let w = open[id] { w.makeKeyAndOrderFront(nil); return }
        let hosting = NSHostingController(rootView: SnippetsView(machine: name, model: SnippetsModel(set), paste: paste))
        // the window's size is the user's (it resizes; the table fills it): sized by its content, a long line that
        // wraps kept SwiftUI and AppKit re-measuring it until AppKit gave up ("more Update Constraints passes than views")
        hosting.sizingOptions = []
        let w = NSWindow(contentViewController: hosting)
        w.title = "\(name): Snippets"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 760, height: 460)); w.contentMinSize = NSSize(width: 640, height: 380)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in open[id] = nil }
        open[id] = w
        if let parent {
            var f = w.frame; f.origin = NSPoint(x: parent.frame.midX - f.width / 2, y: parent.frame.midY - f.height / 2); w.setFrame(f, display: false)
        } else if let machine {
            MachineWindowPlacement.place(w, for: machine)
        } else {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
    }
}
