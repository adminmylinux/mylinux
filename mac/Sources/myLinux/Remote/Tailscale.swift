import AppKit
import CryptoKit
import SwiftUI

/// Tailscale on this Mac: the machines of its tailnet, from the Mac's own Tailscale client (`tailscale status --json`,
/// no API key: the Mac is signed in already, or signs in here), and the way to reach them. The Tailscale app routes
/// the tailnet's addresses itself; a tailscaled in userspace mode (Homebrew's, `--tun=userspace-networking`) does not,
/// so a connection to a tailnet address goes through `tailscale nc` instead: ssh's ProxyCommand, and for VNC (which
/// libvncclient connects itself) a forwarder on 127.0.0.1 that runs `tailscale nc` for each connection.
enum Tailscale {
    struct Client: Codable, Equatable {
        var tool: String
        var socket: String?
        var arguments: [String] { socket.map { ["--socket=\($0)"] } ?? [] }
    }

    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String            // the machine's host name
        let dnsName: String         // name.tailnet.ts.net
        let ip: String              // its first IPv4 address
        let os: String
        let online: Bool
        let lastSeen: Date?
        var host: String { ip.isEmpty ? dnsName : ip }
    }

    struct Status: Equatable {
        var state: String           // Running, NeedsLogin, Stopped, ...
        var tailnet: String
        var userspace: Bool         // not a system network interface: tailnet addresses need `tailscale nc`
        var authURL: String
        var selfName: String
        var peers: [Peer]
    }

    enum Found: Equatable {
        case notInstalled
        case notRunning(String)
        case status(Client, Status)
    }

    // ---- what this Mac has: remembered, so a saved connection to a tailnet address is routed from the start ----
    private static let lock = NSLock()
    private static var _client: Client? = {
        guard let d = UserDefaults.standard.data(forKey: "tailscale.client") else { return nil }
        return try? JSONDecoder().decode(Client.self, from: d)
    }()
    private static var _userspace = UserDefaults.standard.bool(forKey: "tailscale.userspace")
    private static var _names: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "tailscale.names") ?? [])

    static var client: Client? { lock.lock(); defer { lock.unlock() }; return _client }
    static var userspace: Bool { lock.lock(); defer { lock.unlock() }; return _userspace }

    private static func remember(_ c: Client, _ s: Status) {
        lock.lock()
        _client = c; _userspace = s.userspace
        _names = Set(s.peers.flatMap { [$0.name.lowercased(), $0.dnsName.lowercased()] }.filter { !$0.isEmpty })
        let names = Array(_names)
        lock.unlock()
        UserDefaults.standard.set(try? JSONEncoder().encode(c), forKey: "tailscale.client")
        UserDefaults.standard.set(s.userspace, forKey: "tailscale.userspace")
        UserDefaults.standard.set(names, forKey: "tailscale.names")
        if s.userspace { writeScript(c) }
    }

    /// Looks again in the background (at the launcher's start), so the routing knows the Mac's Tailscale.
    static func refreshInBackground() {
        DispatchQueue.global(qos: .utility).async { _ = detect() }
    }

    // ---- finding the client ----------------------------------------------------------------------------------------
    static let appTool = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    /// The CLIs there are, each with the sockets there are: a userspace tailscaled named with --socket first (as
    /// `ps` shows it), then the usual places, then the CLI's own default; the Tailscale app's CLI last.
    static func candidates() -> [Client] {
        let fm = FileManager.default
        let tools = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"].filter { fm.isExecutableFile(atPath: $0) }
        var sockets = runningSockets()
        for s in ["\(NSHomeDirectory())/.tailscale/tailscaled.sock", "/var/run/tailscaled.socket", "/var/run/tailscale/tailscaled.sock"]
        where fm.fileExists(atPath: s) && !sockets.contains(s) { sockets.append(s) }
        var out: [Client] = []
        for t in tools {
            out += sockets.map { Client(tool: t, socket: $0) }
            out.append(Client(tool: t, socket: nil))
        }
        if fm.isExecutableFile(atPath: appTool) { out.append(Client(tool: appTool, socket: nil)) }
        if let last = client, let i = out.firstIndex(of: last) { out.insert(out.remove(at: i), at: 0) }
        return out
    }

    /// `--socket` of the tailscaled processes running.
    static func runningSockets() -> [String] {
        guard let (rc, data) = run("/bin/ps", ["-axo", "command"], timeout: 5), rc == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").filter { $0.contains("tailscaled") }.compactMap { line in
            let words = line.split(separator: " ").map(String.init)
            for (i, w) in words.enumerated() {
                if w.hasPrefix("--socket=") { return String(w.dropFirst("--socket=".count)) }
                if w == "--socket" || w == "-socket", i + 1 < words.count { return words[i + 1] }
            }
            return nil
        }
    }

    /// The first client that answers, and what it says; slow (a few seconds when one hangs): not on the main thread.
    static func detect() -> Found {
        let all = candidates()
        guard !all.isEmpty else { return .notInstalled }
        var why = "Tailscale is installed but not running."
        for c in all {
            guard let (rc, data) = run(c.tool, c.arguments + ["status", "--json"], timeout: 6) else { continue }
            if let s = parse(data) {
                remember(c, s)
                return .status(c, s)
            }
            if rc != 0, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                why = String(text.prefix(300))
            }
        }
        return .notRunning(why)
    }

    static func parse(_ data: Data) -> Status? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let state = o["BackendState"] as? String else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func date(_ s: Any?) -> Date? {
            guard let s = s as? String, !s.hasPrefix("0001") else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }
        let peers: [Peer] = ((o["Peer"] as? [String: [String: Any]]) ?? [:]).values.map { p in
            let ips = p["TailscaleIPs"] as? [String] ?? []
            return Peer(id: (p["ID"] as? String) ?? (p["PublicKey"] as? String) ?? UUID().uuidString,
                        name: p["HostName"] as? String ?? "?",
                        dnsName: (p["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                        ip: ips.first { $0.contains(".") } ?? ips.first ?? "",
                        os: p["OS"] as? String ?? "",
                        online: p["Online"] as? Bool ?? false,
                        lastSeen: date(p["LastSeen"]))
        }
        let me = o["Self"] as? [String: Any]
        return Status(state: state, tailnet: (o["CurrentTailnet"] as? [String: Any])?["Name"] as? String ?? "",
                      userspace: (o["TUN"] as? Bool) == false, authURL: o["AuthURL"] as? String ?? "",
                      selfName: me?["HostName"] as? String ?? "",
                      peers: peers.sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) })
    }

    /// A tool's exit status and output (stdout and stderr), or nil when it could not start or did not end in time.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> (Int32, Data)? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        var out = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let read = DispatchSemaphore(value: 0)
        reader.async { out = pipe.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        _ = read.wait(timeout: .now() + 2)
        return (p.terminationStatus, out)
    }

    // ---- signing in ----------------------------------------------------------------------------------------------------
    /// `tailscale login` (or `up`, to turn a stopped one on): runs in the background; the sign-in page opens from
    /// the status's AuthURL, which the window watches. Returns the process, or what went wrong.
    static func start(_ command: String, with c: Client) -> Result<Process, Error> {
        let p = Process(); p.executableURL = URL(fileURLWithPath: c.tool); p.arguments = c.arguments + [command]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); return .success(p) } catch { return .failure(error) }
    }

    // ---- routing ---------------------------------------------------------------------------------------------------------
    /// A tailnet address: 100.64.0.0/10, a *.ts.net name, or the name of one of the tailnet's machines.
    static func isTailnet(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return true }
        if h.hasSuffix(".ts.net") { return true }
        lock.lock(); defer { lock.unlock() }
        return _names.contains(h)
    }

    /// Whether a connection to `host` has to go through `tailscale nc`.
    static func needsRoute(_ host: String) -> Bool { userspace && client != nil && isTailnet(host) }

    /// The helper ssh and the forwarder run: `tailscale nc <host> <port>` with this Mac's client.
    static var script = Paths.support.appendingPathComponent("tailscale-nc.sh")      // a test points it at its own

    private static func writeScript(_ c: Client) {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let text = "#!/bin/sh\n# myLinux Launcher: a connection into the tailnet through this Mac's userspace Tailscale\nexec \(([c.tool] + c.arguments).map(q).joined(separator: " ")) nc \"$1\" \"$2\"\n"
        if (try? String(contentsOf: script, encoding: .utf8)) != text {
            try? FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
    }

    /// ssh's options for `host`: its ProxyCommand when the tailnet needs `tailscale nc`.
    static func sshOptions(for host: String) -> [String] {
        guard needsRoute(host) else { return [] }
        return ["-o", "ProxyCommand=/bin/sh \"\(script.path)\" %h %p"]
    }

    /// Where to connect for `host:port`: itself, or the local forwarder into the tailnet.
    static func endpoint(_ host: String, _ port: Int) -> (host: String, port: Int, routed: Bool) {
        guard needsRoute(host), let f = Forwarder.to(host, port) else { return (host, port, false) }
        return ("127.0.0.1", f.localPort, true)
    }

    /// 127.0.0.1:<free port>, each connection handed to `tailscale nc host port` (its stdin and stdout are the socket).
    final class Forwarder {
        private static var all: [String: Forwarder] = [:]
        private static let lock = NSLock()
        let localPort: Int
        private let listener: Int32
        private let host: String, port: Int
        private var children: Set<Process> = []
        private let childLock = NSLock()

        static func to(_ host: String, _ port: Int) -> Forwarder? {
            lock.lock(); defer { lock.unlock() }
            let key = "\(host):\(port)"
            if let f = all[key] { return f }
            guard let f = Forwarder(host: host, port: port) else { return nil }
            all[key] = f
            return f
        }

        private init?(host: String, port: Int) {
            self.host = host; self.port = port
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) { a in
                a.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
            }
            guard ok, listen(fd, 8) == 0 else { close(fd); return nil }
            listener = fd
            localPort = Int(UInt16(bigEndian: addr.sin_port))
            let t = Thread { [self] in serve() }
            t.name = "tailscale forwarder \(host):\(port)"; t.start()
        }

        private func serve() {
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [Tailscale.script.path, host, String(port)]
                let h = FileHandle(fileDescriptor: c, closeOnDealloc: false)
                p.standardInput = h; p.standardOutput = h; p.standardError = FileHandle.nullDevice
                p.terminationHandler = { [weak self] done in self?.childLock.lock(); self?.children.remove(done); self?.childLock.unlock() }
                childLock.lock(); children.insert(p); childLock.unlock()
                do { try p.run() } catch { childLock.lock(); children.remove(p); childLock.unlock() }
                close(c)            // the child has its own copy
            }
        }
    }

    // ---- connecting to a tailnet machine -----------------------------------------------------------------------------
    /// The profile for a peer: a saved one for the same machine and kind, or one made for it (not saved: an id of
    /// its own, derived from the peer's, so a password remembered in the Keychain is found again next time).
    static func profile(for peer: Peer, kind: RemoteProfile.Kind) -> RemoteProfile {
        let names = Set([peer.ip, peer.dnsName, peer.name].map { $0.lowercased() }.filter { !$0.isEmpty })
        if let saved = RemoteStore.shared.profiles.first(where: { $0.kind == kind && names.contains($0.host.lowercased()) }) { return saved }
        var p = RemoteProfile(kind: kind)
        p.id = stableID("tailscale:\(kind.rawValue):\(peer.id)")
        p.name = peer.name
        p.host = peer.host
        p.username = UserDefaults.standard.string(forKey: userKey(peer, kind)) ?? ""
        p.hasPassword = RemoteSecrets.password(for: p) != nil
        return p
    }

    static func userKey(_ peer: Peer, _ kind: RemoteProfile.Kind) -> String { "tailscale.user.\(kind.rawValue).\(peer.id)" }

    static func stableID(_ text: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80      // a name-based UUID's version and variant bits
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

// ---- the window ----------------------------------------------------------------------------------------------------
@MainActor
final class TailscaleModel: ObservableObject {
    enum Phase: Equatable { case loading, notInstalled, notRunning(String), signedOut, stopped, running }
    @Published var phase = Phase.loading
    @Published var status: Tailscale.Status?
    @Published var client: Tailscale.Client?
    @Published var search = ""
    @Published var busy = ""                // "Waiting for the sign-in in your browser…" and the like
    @Published var problem = ""
    private var loginProcess: Process?
    private var openedAuthURL = ""
    private var timer: Timer?

    var shown: [Tailscale.Peer] {
        let peers = status?.peers ?? []
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return peers }
        return peers.filter { p in words.allSatisfy { w in [p.name, p.ip, p.os, p.dnsName].contains { $0.lowercased().contains(w) } } }
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let found = Tailscale.detect()
            await MainActor.run { self.apply(found) }
        }
    }

    private func apply(_ found: Tailscale.Found) {
        switch found {
        case .notInstalled: phase = .notInstalled; status = nil
        case .notRunning(let why): phase = .notRunning(why); status = nil
        case .status(let c, let s):
            client = c; status = s
            switch s.state {
            case "Running": phase = .running; busy = ""; stopWatching()
            case "NeedsLogin", "NeedsMachineAuth", "NoState": phase = .signedOut
            case "Stopped": phase = .stopped
            default: phase = .signedOut
            }
            // the sign-in page, once Tailscale has one
            if !s.authURL.isEmpty, s.authURL != openedAuthURL, let u = URL(string: s.authURL) {
                openedAuthURL = s.authURL
                NSWorkspace.shared.open(u)
            }
        }
    }

    func signIn() { begin("login", words: "Waiting for the sign-in in your browser…") }
    func turnOn() { begin("up", words: "Connecting…") }

    private func begin(_ command: String, words: String) {
        guard let c = client else { return }
        problem = ""
        switch Tailscale.start(command, with: c) {
        case .success(let p): loginProcess = p; busy = words; watch()
        case .failure(let e): problem = "Could not run tailscale \(command): \(e.localizedDescription)"
        }
    }

    private func watch() {
        timer?.invalidate()
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                ticks += 1
                if ticks > 150 { self.stopWatching(); self.busy = ""; return }       // five minutes
                self.refresh()
            }
        }
    }

    private func stopWatching() {
        timer?.invalidate(); timer = nil
        if let p = loginProcess, p.isRunning { p.terminate() }
        loginProcess = nil
    }

    func connect(_ peer: Tailscale.Peer, _ kind: RemoteProfile.Kind, askUser: Bool = false) {
        var p = Tailscale.profile(for: peer, kind: kind)
        let saved = RemoteStore.shared.profiles.contains { $0.id == p.id }
        let known = UserDefaults.standard.object(forKey: Tailscale.userKey(peer, kind)) != nil
        // the first time (or Connect As…): the user name, which the tailnet does not know
        if !saved && (askUser || !known) {
            guard let user = askUserName(peer, kind, current: p.username.isEmpty && kind == .ssh ? NSUserName() : p.username) else { return }
            UserDefaults.standard.set(user, forKey: Tailscale.userKey(peer, kind))
            p.username = user
        }
        RemoteWindowController.show(p)
    }

    func addToSidebar(_ peer: Tailscale.Peer, _ kind: RemoteProfile.Kind) {
        let p = Tailscale.profile(for: peer, kind: kind)
        guard !RemoteStore.shared.profiles.contains(where: { $0.id == p.id }) else { return }
        RemoteStore.shared.profiles.append(p)
    }

    private func askUserName(_ peer: Tailscale.Peer, _ kind: RemoteProfile.Kind, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = kind == .ssh ? "SSH to \(peer.name) as" : "VNC to \(peer.name)"
        alert.informativeText = kind == .ssh ? "The user name on \(peer.name). It is remembered for next time."
            : "A user name, only if its VNC server asks for one (wayvnc with a login does). Leave it empty otherwise. It is remembered for next time."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current; field.placeholderString = kind == .ssh ? "user name" : "user name (optional)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }
}

struct TailscaleView: View {
    @StateObject private var model = TailscaleModel()
    @State private var selection = Set<Tailscale.Peer.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.phase {
            case .loading:
                centered { ProgressView("Looking for Tailscale on this Mac…") }
            case .notInstalled:
                centered {
                    Text("Tailscale is not installed on this Mac.").font(.headline)
                    Text("Install it, sign in, and your machines show here.").foregroundStyle(.secondary)
                    Link("Download Tailscale", destination: URL(string: "https://tailscale.com/download/mac")!)
                }
            case .notRunning(let why):
                centered {
                    Text("Tailscale is not running.").font(.headline)
                    Text(why).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                    Button("Open Tailscale") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }
                }
            case .signedOut:
                centered {
                    Text("This Mac is not signed in to Tailscale.").font(.headline)
                    Text("Sign in, in your browser; the machines of your tailnet show here after.").foregroundStyle(.secondary)
                    Button("Sign In to Tailscale") { model.signIn() }.buttonStyle(.borderedProminent).disabled(!model.busy.isEmpty)
                }
            case .stopped:
                centered {
                    Text("Tailscale is off on this Mac.").font(.headline)
                    Button("Turn On") { model.turnOn() }.buttonStyle(.borderedProminent).disabled(!model.busy.isEmpty)
                }
            case .running:
                list
            }
            if !model.busy.isEmpty { HStack { ProgressView().controlSize(.small); Text(model.busy).foregroundStyle(.secondary) } }
            if !model.problem.isEmpty { Text(model.problem).foregroundStyle(.red).textSelection(.enabled) }
            if model.phase == .running, model.status?.userspace == true {
                Text("This Mac's Tailscale runs in userspace mode: connections go through `tailscale nc`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.grid.3x3.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tailscale").font(.title3.weight(.semibold))
                if let s = model.status, model.phase == .running {
                    Text("\(s.tailnet) · \(s.peers.filter(\.online).count) of \(s.peers.count) online").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.phase == .running {
                TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Look again")
        }
    }

    private var list: some View {
        Table(model.shown, selection: $selection) {
            TableColumn("") { p in
                Circle().fill(p.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                    .help(p.online ? "Online" : "Offline")
            }.width(14)
            TableColumn("Name") { p in
                Text(p.name).fontWeight(.medium).help(p.dnsName)
            }.width(min: 120, ideal: 180)
            TableColumn("IP") { p in
                Text(p.ip).font(.body.monospaced()).textSelection(.enabled)
            }.width(min: 100, ideal: 120)
            TableColumn("Type") { p in
                Label(osTitle(p.os), systemImage: osSymbol(p.os))
            }.width(min: 80, ideal: 100)
            TableColumn("Seen") { p in
                Text(p.online ? "now" : p.lastSeen.map { $0.formatted(.relative(presentation: .named)) } ?? "–").foregroundStyle(.secondary)
            }.width(min: 70, ideal: 100)
            TableColumn("Connect") { p in
                HStack(spacing: 6) {
                    Button { model.connect(p, .vnc) } label: { Image(systemName: "display") }
                        .help("VNC desktop of \(p.name) (port 5900)")
                        .contextMenu { menu(p, .vnc) }
                    Button { model.connect(p, .ssh) } label: { Image(systemName: "terminal") }
                        .help("SSH terminal on \(p.name)")
                        .contextMenu { menu(p, .ssh) }
                }
                .buttonStyle(.borderless)
                .disabled(!p.online)
            }.width(70)
        }
        .contextMenu(forSelectionType: Tailscale.Peer.ID.self) { ids in
            if let id = ids.first, let p = model.shown.first(where: { $0.id == id }) {
                Button("VNC Desktop") { model.connect(p, .vnc) }
                Button("SSH Terminal") { model.connect(p, .ssh) }
                Divider()
                Button("VNC as…") { model.connect(p, .vnc, askUser: true) }
                Button("SSH as…") { model.connect(p, .ssh, askUser: true) }
                Divider()
                Button("Add VNC Desktop to the Sidebar") { model.addToSidebar(p, .vnc) }
                Button("Add SSH Terminal to the Sidebar") { model.addToSidebar(p, .ssh) }
                Divider()
                Button("Copy IP Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.ip, forType: .string) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let p = model.shown.first(where: { $0.id == id }) { model.connect(p, p.os == "linux" ? .ssh : .vnc) }
        }
    }

    @ViewBuilder private func menu(_ p: Tailscale.Peer, _ kind: RemoteProfile.Kind) -> some View {
        Button(kind == .ssh ? "SSH as…" : "VNC as…") { model.connect(p, kind, askUser: true) }
        Button("Add to the Sidebar") { model.addToSidebar(p, kind) }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func osTitle(_ os: String) -> String {
        switch os.lowercased() {
        case "linux": return "Linux"
        case "macos": return "macOS"
        case "windows": return "Windows"
        case "ios": return "iOS"
        case "android": return "Android"
        default: return os.isEmpty ? "?" : os
        }
    }
    private func osSymbol(_ os: String) -> String {
        switch os.lowercased() {
        case "linux": return "server.rack"
        case "macos": return "laptopcomputer"
        case "windows": return "pc"
        case "ios", "android": return "iphone"
        default: return "questionmark.circle"
        }
    }
}

enum TailscaleWindow {
    private static var window: NSWindow?

    static func show() {
        NSApp.activate()
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: TailscaleView()))
        w.title = "Tailscale"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 780, height: 480))
        w.setFrameAutosaveName("tailscale")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in window = nil }
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
