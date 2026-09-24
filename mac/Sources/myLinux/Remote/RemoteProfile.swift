import Foundation
import Security

/// A remote machine reached natively from the Mac: a VNC desktop or an SSH terminal (docs/MAC-REMOTE-PLAN.md).
/// Saved in ~/Library/Application Support/myLinux/remote.json; passwords in the Keychain.
struct RemoteProfile: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable { case vnc, ssh }
    /// Which keys the remote gets while its window is key.
    enum Keyboard: String, Codable, CaseIterable {
        case mac            // ⌘ combinations stay with macOS, the rest goes to the remote
        case optionSuper    // Option acts as the remote's Super key, ⌘ stays with the Mac
        case all            // everything, ⌘Tab and ⌘Space included (event tap, Accessibility); Ctrl+Option+G releases
        var title: String {
            switch self {
            case .mac: return "Mac keeps its shortcuts"
            case .optionSuper: return "Option is Super"
            case .all: return "Everything to the remote"
            }
        }
    }

    var id = UUID()
    var name = ""
    var kind = Kind.vnc
    var host = ""
    var port = 5900
    var username = ""
    var quality = "balanced"        // vnc: fast | balanced | best
    var keyFile = ""                // ssh
    var tmux = ""                   // ssh: attach to this tmux session
    var keyboard = Keyboard.optionSuper
    var keepForMac: [String] = []   // shortcuts the Mac keeps even in "all" mode, e.g. ["cmd+c", "cmd+v"]
    var hasPassword = false         // a password is stored in the Keychain
    /// Extra `-o` options for ssh, set by the launcher for its own machines (a per-machine known_hosts file);
    /// not saved.
    var sshOptions: [String] = []
    /// The terminal of one of the launcher's own machines (a Debian server): its window carries the myLinux menu.
    var launcherMachine = false
    /// The machine's share folder on the Mac and its path inside the machine ("~/Mac"); not saved.
    var shareMacPath = ""
    var shareGuestPath = ""

    init(kind: Kind = .vnc) { self.kind = kind; port = kind == .ssh ? 22 : 5900; keyboard = kind == .ssh ? .mac : .optionSuper }

    enum CodingKeys: String, CodingKey { case id, name, kind, host, port, username, quality, keyFile, tmux, keyboard, keepForMac, hasPassword }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .vnc
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? (kind == .ssh ? 22 : 5900)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        quality = try c.decodeIfPresent(String.self, forKey: .quality) ?? "balanced"
        keyFile = try c.decodeIfPresent(String.self, forKey: .keyFile) ?? ""
        tmux = try c.decodeIfPresent(String.self, forKey: .tmux) ?? ""
        keyboard = try c.decodeIfPresent(Keyboard.self, forKey: .keyboard) ?? (kind == .ssh ? .mac : .optionSuper)
        keepForMac = try c.decodeIfPresent([String].self, forKey: .keepForMac) ?? []
        hasPassword = try c.decodeIfPresent(Bool.self, forKey: .hasPassword) ?? false
    }

    var title: String { name.isEmpty ? host : name }
    var problems: [String] {
        var p: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty { p.append("A host name or address is needed.") }
        if !(1...65535).contains(port) { p.append("The port must be 1–65535.") }
        return p
    }
}

/// The Keychain item for a profile's password: service "myLinux Remote", account "<kind>:<id>".
enum RemoteSecrets {
    static let service = "myLinux Remote"
    static func account(_ p: RemoteProfile) -> String { "\(p.kind.rawValue):\(p.id.uuidString)" }

    static func password(for p: RemoteProfile) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account(p), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    /// Stored through the `security` tool so that the item's access list names both this app and /usr/bin/security:
    /// ssh's askpass helper reads the password with `security find-generic-password` and must not trigger a
    /// Keychain prompt (SecItemAdd cannot add a second trusted application to the item).
    @discardableResult
    static func setPassword(_ password: String, for p: RemoteProfile) -> Bool {
        if password.isEmpty { delete(for: p); return true }
        let me = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["add-generic-password", "-U", "-s", service, "-a", account(p), "-l", "myLinux Remote: \(p.title)", "-T", "/usr/bin/security", "-T", me, "-w", password]
        proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
    static func delete(for p: RemoteProfile) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(p)] as CFDictionary)
    }
}

final class RemoteStore: ObservableObject {
    static let shared = RemoteStore()
    @Published var profiles: [RemoteProfile] = [] { didSet { if loaded { save() } } }
    @Published var lastError: String?
    private var loaded = false
    let file: URL

    init(file: URL = Paths.support.appendingPathComponent("remote.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([RemoteProfile].self, from: data) { profiles = list }
        loaded = true
    }
    @discardableResult
    func add(_ kind: RemoteProfile.Kind) -> RemoteProfile {
        var p = RemoteProfile(kind: kind); p.name = kind == .ssh ? "New SSH terminal" : "New VNC desktop"
        profiles.append(p); return p
    }
    func update(_ p: RemoteProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }), profiles[i] != p else { return }
        profiles[i] = p
    }
    func remove(_ id: UUID) {
        if let p = profiles.first(where: { $0.id == id }) { RemoteSecrets.delete(for: p) }
        profiles.removeAll { $0.id == id }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(profiles).write(to: file, options: .atomic)
            lastError = nil
        } catch { lastError = "Could not save remote machines: \(error.localizedDescription)" }
    }
}
