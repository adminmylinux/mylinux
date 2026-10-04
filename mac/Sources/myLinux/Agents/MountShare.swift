import AppKit
import Network
import SwiftUI

/// Mount a Share…: an SMB share (this Mac's own, a NAS's, a PC's, one on the tailnet) inside a machine at ~/<name>,
/// now and at every start. The dialog asks where; server-apps/mount-share.sh does it inside, in the machine's terminal,
/// which asks for the share's password there (it never passes through the Mac) and for sudo once. The request goes
/// into the Mac share (.mylinux/mount-share.args), which the script reads and removes. A server's window types the
/// line into its terminal; Omarchy's session helper opens a terminal for it ("share").
enum MountShare {
    /// The Mac, as a machine on QEMU's user network sees it.
    static let thisMac = "10.0.2.2"
    static let argsPath = ".mylinux/mount-share.args"
    static let guestLine = " sh /mnt/mac/.mylinux/apps/mount-share.sh --from /mnt/mac/.mylinux/mount-share.args"

    struct Request: Equatable {
        var server = MountShare.thisMac
        var share = ""
        var name = ""
        var user = NSUserName()

        /// What mount-share.sh would refuse, in words; nil when it is fine.
        var problem: String? {
            if server.isEmpty || server.range(of: #"^[A-Za-z0-9.:_-]+$"#, options: .regularExpression) == nil { return "The server is an address or a name, like 10.0.2.2 or 192.168.0.20." }
            if share.isEmpty || share.contains(where: { "/\\,\n".contains($0) }) { return "The share is its name on the server, without / \\ or ,." }
            if name.isEmpty || name.hasPrefix(".") || name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil { return "The name inside is one word: letters, digits, . _ -" }
            if user.range(of: #"^[A-Za-z0-9._@ -]*$"#, options: .regularExpression) == nil { return "The user name has characters an SMB user cannot have." }
            return nil
        }
    }

    /// This Mac's SMB shares (System Settings › General › Sharing › File Sharing), from `sharing -l`.
    static func macShares() -> [String] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/sharing"); p.arguments = ["-l"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return parseShares(text)
    }

    /// The share points that are shared over SMB: each block's smb section with "shared: 1" gives its name.
    static func parseShares(_ text: String) -> [String] {
        var names: [String] = [], inSMB = false, smbName: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("smb:") { inSMB = true; smbName = nil; continue }
            guard inSMB else { continue }
            if line.hasPrefix("}") { inSMB = false; continue }
            if line.hasPrefix("name:") { smbName = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("shared:"), line.hasSuffix("1"), let n = smbName, !names.contains(n) { names.append(n) }
        }
        return names
    }

    /// Whether this Mac answers on SMB's port (File Sharing on).
    static func fileSharingOn() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(445).bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    /// A name for inside from the share's: "Viktor’s Public Folder" → Public, "Media Library" → MediaLibrary.
    static func suggestedName(_ share: String) -> String {
        if share.hasSuffix("Public Folder") { return "Public" }
        let words = share.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" && $0 != "." })
        let ascii = words.map { String($0.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }) }.filter { !$0.isEmpty }
        let joined = ascii.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return String(joined.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// The script into the share (with myLinux Apps) and the request beside it: nil when done, or what went wrong.
    static func prepare(_ r: Request, shareDir: String) async -> String? {
        if let problem = await ServerApps.copy(to: shareDir) { return problem }
        let url = URL(fileURLWithPath: shareDir).appendingPathComponent(argsPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(r.server)\n\(r.share)\n\(r.name)\n\(r.user)\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Could not leave the request in \(url.path): \(error.localizedDescription)"
        }
        return nil
    }

    /// Omarchy: the request, then "share" for its session helper, which opens a terminal running the script.
    static func openInOmarchy(_ r: Request, machine: Profile) async -> String? {
        if let problem = await prepare(r, shareDir: machine.shareDir) { return problem }
        let control = URL(fileURLWithPath: machine.shareDir).appendingPathComponent("mylinux-tools/control", isDirectory: true)
        let cmd = control.appendingPathComponent("share.cmd")
        do {
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            try "share\n".write(to: cmd, atomically: true, encoding: .utf8)
        } catch {
            return "Could not leave the command for Omarchy: \(error.localizedDescription)"
        }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !FileManager.default.fileExists(atPath: cmd.path) { return nil }
        }
        try? FileManager.default.removeItem(at: cmd)
        return "Omarchy's session helper did not answer. It learns Mount a Share… when Omarchy starts again with this launcher "
            + "(Machine › Restart); it also runs only once you are signed in to Omarchy's desktop. Meanwhile, in an Omarchy terminal: "
            + "sh /mnt/mac/.mylinux/apps/mount-share.sh --from /mnt/mac/.mylinux/mount-share.args"
    }
}

/// The file servers on the local network (Bonjour's _smb._tcp: a Synology, another Mac), with their IPv4 addresses: a
/// machine cannot resolve .local names (QEMU's user network does not pass on multicast), so the dialog fills in the
/// address. This Mac itself is left out (it is "This Mac").
@MainActor
final class SMBServers: ObservableObject {
    struct Server: Hashable, Identifiable { let name: String; let address: String; var id: String { name } }
    @Published private(set) var found: [Server] = []
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel(); browser = nil
        resolving.values.forEach { $0.cancel() }; resolving.removeAll()
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        let me = Host.current().localizedName ?? ""
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint, name != me, name != ProcessInfo.processInfo.hostName,
                  resolving[name] == nil, !found.contains(where: { $0.name == name }) else { continue }
            // a connection to the service tells its address; it is closed once it does
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let c = NWConnection(to: r.endpoint, using: params)
            resolving[name] = c
            c.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if case .hostPort(let host, _) = c.currentPath?.remoteEndpoint, case .ipv4(let v4) = host {
                            let address = "\(v4)".components(separatedBy: "%").first ?? "\(v4)"
                            if !self.found.contains(where: { $0.name == name }) {
                                self.found.append(Server(name: name, address: address)); self.found.sort { $0.name < $1.name }
                            }
                        }
                        c.cancel(); self.resolving[name] = nil
                    case .failed, .cancelled:
                        self.resolving[name] = nil
                    default: break
                    }
                }
            }
            c.start(queue: .main)
        }
    }
}

/// The dialog: where the share is, what it is called, the name inside and the user; Mount hands it on.
struct MountShareView: View {
    let machine: String
    let mount: (MountShare.Request) -> Void
    let cancel: () -> Void
    @State private var r = MountShare.Request()
    @State private var nameEdited = false
    @State private var shares: [String] = []
    @State private var sharingOn = true
    @StateObject private var network = SMBServers()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 26)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mount a Share in \(machine)").font(.title3.weight(.semibold))
                    Text("An SMB share from this Mac, a NAS or another computer, as a folder in your home inside.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Server").gridColumnAlignment(.trailing)
                    HStack {
                        TextField("10.0.2.2", text: $r.server).textFieldStyle(.roundedBorder)
                        Menu {
                            Button("This Mac (\(MountShare.thisMac))") { r.server = MountShare.thisMac; if r.user.isEmpty { r.user = NSUserName() } }
                            Section("On your network") {
                                if network.found.isEmpty { Text("Looking…") }
                                ForEach(network.found) { s in
                                    Button("\(s.name) (\(s.address))") {
                                        r.server = s.address
                                        if r.server != MountShare.thisMac && r.user == NSUserName() { r.user = "" }
                                        if shares.contains(r.share) { r.share = ""; r.name = "" }
                                    }
                                }
                            }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                GridRow {
                    Text("Share")
                    HStack {
                        TextField("Its name on the server", text: $r.share).textFieldStyle(.roundedBorder)
                            .onChange(of: r.share) { _, v in if !nameEdited { r.name = MountShare.suggestedName(v) } }
                        if r.server == MountShare.thisMac {
                            Menu {
                                // what this Mac offers: its shared folders (File Sharing), and to your own account your home
                                Section("Shared folders") {
                                    if shares.isEmpty { Text("None yet") }
                                    ForEach(shares, id: \.self) { s in Button(s) { r.share = s } }
                                }
                                Section("With your account") {
                                    Button("Your home folder (\(NSUserName()))") {
                                        r.share = NSUserName(); r.name = "MacHome"; nameEdited = true; r.user = NSUserName()
                                    }
                                }
                                Divider()
                                Button("Share Another Folder…") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
                                }
                            } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("What this Mac shares")
                        }
                    }
                }
                GridRow {
                    Text("Name inside")
                    HStack(spacing: 6) {
                        Text("~/").foregroundStyle(.secondary).font(.body.monospaced())
                        TextField("Public", text: $r.name).textFieldStyle(.roundedBorder)
                            .onChange(of: r.name) { _, v in nameEdited = !v.isEmpty && v != MountShare.suggestedName(r.share) }
                    }
                }
                GridRow {
                    Text("User")
                    TextField("Empty for a guest share", text: $r.user).textFieldStyle(.roundedBorder)
                }
            }
            if r.server == MountShare.thisMac && !sharingOn {
                HStack(alignment: .top) {
                    Label("This Mac's File Sharing is off: turn it on, with SMB for your account.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Sharing Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
                    }
                }
            }
            Text("The machine's terminal asks for the share's password (empty for a guest share) and your sudo password once. ~/\(r.name.isEmpty ? "name" : r.name) comes back at every start. A Tailscale address works when this Mac runs the Tailscale app.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let p = r.problem, !(r.share.isEmpty && r.name.isEmpty) {
                Text(p).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Mount") { mount(r) }.keyboardShortcut(.defaultAction).disabled(r.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { network.stop() }
        .onAppear {
            network.start()
            DispatchQueue.global(qos: .userInitiated).async {
                let list = MountShare.macShares(), on = MountShare.fileSharingOn()
                DispatchQueue.main.async {
                    shares = list; sharingOn = on
                    if r.share.isEmpty, let first = list.first { r.share = first }
                }
            }
        }
    }
}

/// The dialog in a window of its own, for a desktop machine (Omarchy's ⌘ menu, through MachineLink).
enum MountShareWindow {
    private static var open: [UUID: NSWindow] = [:]

    static func show(_ machine: Profile) {
        NSApp.activate()
        if let w = open[machine.id] { w.makeKeyAndOrderFront(nil); return }
        var window: NSWindow?
        let view = MountShareView(machine: machine.name, mount: { r in
            window?.close()
            Task { @MainActor in
                guard let problem = await MountShare.openInOmarchy(r, machine: machine) else { return }
                NSApp.activate()
                let alert = NSAlert(); alert.messageText = "Mount a Share in \(machine.name)"; alert.informativeText = problem
                alert.runModal()
            }
        }, cancel: { window?.close() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]    // sized from the view once, not a layout loop with the window
        let w = NSWindow(contentViewController: hosting)
        window = w
        w.title = "\(machine.name): Mount a Share"
        w.styleMask = [.titled, .closable]
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in open[machine.id] = nil }
        open[machine.id] = w
        MachineWindowPlacement.place(w, for: machine)     // in front of the machine's own window, on its screen
        w.makeKeyAndOrderFront(nil)
    }
}
