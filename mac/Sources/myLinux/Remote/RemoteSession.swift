import Foundation

/// The remote windows open right now, remembered across a launcher restart (the myLinux viewer's rule): written
/// whenever a remote window opens or closes, removed when the last one is closed on purpose, left in place by a
/// quit or a crash so the next launch opens them again. ~/Library/Application Support/myLinux/remote-session.json
enum RemoteSession {
    static var file: URL { Paths.support.appendingPathComponent("remote-session.json") }
    /// Set while the app quits: windows closing then are not closed on purpose, the file stays.
    static var quitting = false

    static func save(_ ids: [UUID], to file: URL = file) {
        if ids.isEmpty { try? FileManager.default.removeItem(at: file); return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ids.map(\.uuidString)).write(to: file, options: .atomic)
    }
    static func load(from file: URL = file) -> [UUID] {
        guard let d = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return list.compactMap(UUID.init(uuidString:))
    }
    /// The window controller calls this after its list of open windows changed.
    static func noteOpenWindows() {
        guard !quitting, !MachineApp.active else { return }      // a machine's own app: the file is the launcher's
        save(RemoteWindowController.open.map { $0.profile.id })
    }
    /// At launch: the remembered profiles that still exist, in the order they were opened.
    static func restore(store: RemoteStore = .shared) -> [RemoteProfile] {
        load().compactMap { id in store.profiles.first { $0.id == id } }
    }
}

/// URLs that open a machine, for the Dock's myLinux icon, Shortcuts and scripts (`open mylinux://vnc/omarchy`):
/// mylinux://vnc/<name>, mylinux://ssh/<name>, mylinux://remote/<name or id>; mylinux-launcher://start and
/// mylinux-launcher://remote/<id> from earlier builds keep working. The name is matched as the profile's name, then
/// its host (case-insensitive), or its id.
enum RemoteLink {
    /// start: the machine used last; startMachine: one machine (its own app in the Dock sends mylinux-launcher://start/<id>)
    enum Target: Equatable { case start; case startMachine(UUID); case remote(kind: RemoteProfile.Kind?, name: String) }

    static func parse(_ url: URL) -> Target? {
        guard url.scheme == "mylinux" || url.scheme == "mylinux-launcher" else { return nil }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch url.host {
        case "start": return UUID(uuidString: name).map { .startMachine($0) } ?? .start
        case "vnc": return .remote(kind: .vnc, name: name)
        case "ssh": return .remote(kind: .ssh, name: name)
        case "remote": return .remote(kind: nil, name: name)
        default: return nil
        }
    }
}

extension RemoteStore {
    /// A profile by id, name or host (case-insensitive), optionally of one kind.
    func find(_ name: String, kind: RemoteProfile.Kind? = nil) -> RemoteProfile? {
        let list = profiles.filter { kind == nil || $0.kind == kind }
        if let id = UUID(uuidString: name), let p = list.first(where: { $0.id == id }) { return p }
        let n = name.lowercased()
        guard !n.isEmpty else { return nil }
        return list.first { $0.name.lowercased() == n } ?? list.first { $0.host.lowercased() == n }
    }
}

/// Import from the myLinux viewer's machines.json (shell/vncview/machines.h): entries with name, type vnc|ssh (older
/// files: vnc only), host, port, username, quality, keyFile, tmux. Passwords sit in the guest's secrets.env next to
/// the vnc/ folder as VNC_<NAME>_PASSWORD or SSH_<NAME>_PASSWORD (the viewer's secretKey rule). The guest keeps both
/// under ~/.config/mylinux on its apps disk, so copy them to the share (or anywhere the Mac can read) to import.
enum RemoteImport {
    struct Entry: Equatable { var profile: RemoteProfile; var password: String? }

    static func parse(_ data: Data) throws -> [RemoteProfile] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "RemoteImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a machines.json list."])
        }
        return list.compactMap { e in
            let kind: RemoteProfile.Kind = (e["type"] as? String) == "ssh" ? .ssh : .vnc
            var p = RemoteProfile(kind: kind)
            p.name = e["name"] as? String ?? ""
            p.host = e["host"] as? String ?? ""
            if let n = e["port"] as? Int { p.port = n } else if let s = e["port"] as? String, let n = Int(s) { p.port = n }
            p.username = e["username"] as? String ?? ""
            if let q = e["quality"] as? String, !q.isEmpty { p.quality = q }
            p.keyFile = e["keyFile"] as? String ?? ""
            p.tmux = e["tmux"] as? String ?? ""
            return p.host.isEmpty ? nil : p
        }
    }

    /// The secrets.env key for a machine (Machines::secretKey in the viewer).
    static func secretKey(name: String, kind: RemoteProfile.Kind) -> String {
        var k = name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
            .split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        if k.isEmpty { k = "DEFAULT" }
        return (kind == .ssh ? "SSH_" : "VNC_") + k + "_PASSWORD"
    }

    /// KEY=value lines; older files wrote KEY='value' with '\'' for a quote.
    static func passwords(_ env: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in env.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq > line.startIndex else { continue }
            let key = String(line[..<eq]); var v = String(line[line.index(after: eq)...])
            if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") { v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'") }
            else if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            out[key] = v
        }
        return out
    }

    /// Reads machines.json and, when a secrets.env sits next to it or one folder up, the passwords.
    static func load(_ url: URL) throws -> [Entry] {
        let profiles = try parse(Data(contentsOf: url))
        let dir = url.deletingLastPathComponent()
        let env = [dir, dir.deletingLastPathComponent()].map { $0.appendingPathComponent("secrets.env") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first.map(passwords) ?? [:]
        return profiles.map { p in Entry(profile: p, password: env[secretKey(name: p.name, kind: p.kind)]) }
    }
}

extension RemoteStore {
    /// Adds imported machines; one with the same name and kind as an existing profile updates it in place (keeping
    /// its id, keyboard mode and window). A password that came along goes to the Keychain.
    @discardableResult
    func merge(_ entries: [RemoteImport.Entry], savePassword: (String, RemoteProfile) -> Bool = { RemoteSecrets.setPassword($0, for: $1) }) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for e in entries {
            var p = e.profile
            if let i = profiles.firstIndex(where: { $0.kind == p.kind && $0.name.lowercased() == p.name.lowercased() && !p.name.isEmpty }) {
                var cur = profiles[i]
                cur.host = p.host; cur.port = p.port; cur.username = p.username; cur.quality = p.quality; cur.keyFile = p.keyFile; cur.tmux = p.tmux
                if let pw = e.password, !pw.isEmpty, savePassword(pw, cur) { cur.hasPassword = true }
                if cur != profiles[i] { profiles[i] = cur; updated += 1 }
            } else {
                if let pw = e.password, !pw.isEmpty, savePassword(pw, p) { p.hasPassword = true }
                profiles.append(p); added += 1
            }
        }
        return (added, updated)
    }
}
