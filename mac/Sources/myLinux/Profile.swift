import Foundation

/// One saved way to start myLinux: keyboard and mouse handling, machine size, and which apps disk and share
/// folder it uses (separate disks are separate myLinux installs). Maps onto run.sh's environment.
struct Profile: Codable, Identifiable, Hashable {
    /// What runs in the machine. myLinux is run.sh: the RAM-resident image plus an apps disk. Omarchy is
    /// run-omarchy.sh: the Try Omarchy guest on the accelerated QEMU runtime, where `appsDisk` is the machine's root
    /// disk (its kernel and initramfs sit in boot/ beside it) and `appsSizeGB` the size that disk is created with.
    /// Debian and Alpine are servers (run-debian.sh, run-alpine.sh, both run-server.sh): terminal-only machines from
    /// the distribution's cloud image, `appsDisk` their root disk, no window; the launcher reaches them through the
    /// serial console and an SSH terminal on `sshPort`.
    enum Kind: String, Codable {
        case mylinux, omarchy, debian, alpine
        var isServer: Bool { self == .debian || self == .alpine }
        var title: String {
            switch self { case .mylinux: return "myLinux"; case .omarchy: return "Omarchy"; case .debian: return "Debian"; case .alpine: return "Alpine" }
        }
        /// A server's account inside: "debian" (bash, sudo) or Alpine's own "alpine" (ash until the install script, doas).
        var serverUser: String { rawValue }
        /// What Install Script… loads for a server: debian_install.sh, alpine_install.sh.
        var installScriptName: String { "\(rawValue)_install.sh" }
    }
    var isServer: Bool { kind.isServer }

    var id = UUID()
    var kind = Kind.mylinux
    var name = "myLinux"
    var grab = "opt"            // GRAB: opt | full | none
    var mouse = "tablet"        // MOUSE: tablet | relative
    var clipboard = true        // CLIPBOARD
    var memoryGB = 6            // MEM
    var memoryAuto = true       // memoryGB follows the Mac's memory (recommendedMemoryGB), set at every launcher start
    var resolution = ""         // RES: "" fits the screen the pointer is on, else WxH
    var appsSizeGB = 16         // APPS_SIZE_GB, used when the disk is created
    var appsDisk = ""           // APPS_IMG
    var shareDir = ""           // SHARE_DIR
    // Omarchy machines only (run-omarchy.sh)
    var cpus = 0                // CPUS: 0 lets the script choose from the Mac's core count
    var sound = true            // AUDIO
    var sshPort = 0             // SSH=1 and FORWARD=<port>:22 when not 0: ssh -p <port> <user>@127.0.0.1 from the Mac
    var cloudFolders: [String] = []   // servers: CloudFolder raw values, shared inside beside ~/Mac (EXTRA_SHARES)

    init(name: String, appsDisk: String, shareDir: String) {
        self.name = name; self.appsDisk = appsDisk; self.shareDir = shareDir
    }

    // tolerant decoding: fields added later get their defaults instead of dropping the whole file
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .mylinux      // an unknown kind from a newer app: myLinux
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "myLinux"
        grab = try c.decodeIfPresent(String.self, forKey: .grab) ?? "opt"
        mouse = try c.decodeIfPresent(String.self, forKey: .mouse) ?? "tablet"
        clipboard = try c.decodeIfPresent(Bool.self, forKey: .clipboard) ?? true
        memoryGB = try c.decodeIfPresent(Int.self, forKey: .memoryGB) ?? 6
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? ""
        appsSizeGB = try c.decodeIfPresent(Int.self, forKey: .appsSizeGB) ?? 16
        appsDisk = try c.decodeIfPresent(String.self, forKey: .appsDisk) ?? ""
        shareDir = try c.decodeIfPresent(String.self, forKey: .shareDir) ?? ""
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 0
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 0
        cloudFolders = try c.decodeIfPresent([String].self, forKey: .cloudFolders) ?? []
        // saved before Automatic existed: automatic when still at that launcher's fixed default, else the user's choice
        memoryAuto = try c.decodeIfPresent(Bool.self, forKey: .memoryAuto) ?? (memoryGB == Profile.legacyMemoryGB[kind])
    }

    /// The fixed memory sizes launchers up to 0.3.7 gave new machines.
    static let legacyMemoryGB: [Kind: Int] = [.mylinux: 6, .omarchy: 8, .debian: 2]

    /// Memory for a machine of this kind on a Mac with `macGB` of memory: enough for its desktop (or, for Debian, the
    /// coding agents and a build), while leaving macOS room on an 8 GB Mac.
    static func recommendedMemoryGB(_ kind: Kind, macGB: Int = Profile.macMemoryGB) -> Int {
        let tier = macGB < 12 ? 0 : macGB < 24 ? 1 : 2       // 8 GB · 16 GB · 24 GB and more
        switch kind {
        case .mylinux: return [3, 4, 6][tier]
        case .omarchy: return [4, 6, 8][tier]
        case .debian: return [2, 2, 4][tier]
        case .alpine: return [1, 1, 2][tier]
        }
    }
    static var macMemoryGB: Int { Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30) }

    /// Sets an automatic machine's memory from the Mac's; returns whether it changed.
    @discardableResult mutating func applyAutomaticMemory(macGB: Int = Profile.macMemoryGB) -> Bool {
        guard memoryAuto else { return false }
        let gb = Profile.recommendedMemoryGB(kind, macGB: macGB)
        if memoryGB == gb { return false }
        memoryGB = gb; return true
    }

    /// The QEMU window title and run.sh instance name. The first profile keeps the plain name.
    var windowName: String {
        if kind != .mylinux { return name }
        return name == "myLinux" ? "myLinux" : "myLinux (\(name))"
    }
    /// The script that starts this kind of machine, relative to the scripts folder.
    var script: String { kind == .omarchy ? "run-omarchy.sh" : kind.isServer ? "run-\(kind.rawValue).sh" : "run.sh" }
    /// A server's folder (its disk, SSH key, console password and seed live there).
    var machineFolder: URL { URL(fileURLWithPath: appsDisk).deletingLastPathComponent() }
    /// The SSH terminal to a server: keyed by the machine's id, so a second request brings the same window
    /// forward; the machine's own key and known_hosts; the share, for screenshots into it.
    var terminalProfile: RemoteProfile {
        var p = RemoteProfile(kind: .ssh)
        p.id = id; p.name = "\(name) terminal"; p.host = "127.0.0.1"; p.port = sshPort; p.username = kind.serverUser
        p.keyFile = machineFolder.appendingPathComponent("ssh_key").path
        p.sshOptions = [RemoteProfile.knownHostsOption(machineFolder.appendingPathComponent("known_hosts").path), "ConnectTimeout=10"]
        p.keyboard = .mac; p.launcherMachine = true; p.installScript = kind.installScriptName; p.machineID = id
        if !shareDir.isEmpty { p.shareMacPath = shareDir; p.shareGuestPath = "~/" + URL(fileURLWithPath: shareDir).lastPathComponent }
        return p
    }

    /// Problems that would make run.sh refuse to start, in words for the form.
    var problems: [String] {
        var p: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("The profile needs a name.") }
        if !resolution.isEmpty {
            let parts = resolution.lowercased().split(separator: "x")
            let ok = parts.count == 2 && parts.allSatisfy { Int($0).map { (480...8192).contains($0) } ?? false }
                && (Int(parts[0]) ?? 0) >= 640
            if !ok { p.append("Resolution must look like 1920x1200 (640–8192 wide, 480–8192 high).") }
        }
        if isServer {
            if appsDisk.isEmpty { p.append("Choose where the machine's disk lives.") }
            if !(8...2000).contains(appsSizeGB) { p.append("Disk size must be 8–2000 GB.") }
            if shareDir.contains(",") || appsDisk.contains(",") { p.append("Paths must not contain a comma.") }
            if !(1024...65535).contains(sshPort) { p.append("The SSH port must be 1024–65535.") }
            if cpus < 0 || cpus > ProcessInfo.processInfo.processorCount { p.append("This Mac has \(ProcessInfo.processInfo.processorCount) processor cores.") }
            return p
        }
        if kind == .omarchy {
            if appsDisk.isEmpty { p.append("Choose where the machine's disk lives.") }
            if !(8...2000).contains(appsSizeGB) { p.append("Disk size must be 8–2000 GB.") }
            if shareDir.contains(",") { p.append("The share folder's path must not contain a comma.") }
            if sshPort != 0 && !(1024...65535).contains(sshPort) { p.append("The SSH port must be 1024–65535.") }
            if cpus < 0 || cpus > ProcessInfo.processInfo.processorCount { p.append("This Mac has \(ProcessInfo.processInfo.processorCount) processor cores.") }
            return p                                 // the share folder is optional for Omarchy
        }
        if appsDisk.isEmpty { p.append("Choose where the apps disk lives.") }
        if shareDir.isEmpty { p.append("Choose a share folder.") }
        if !(4...2000).contains(appsSizeGB) { p.append("Apps disk size must be 4–2000 GB.") }
        return p
    }

    /// run.sh's environment for this profile.
    func environment(outDir: URL, serialSocket: String, qmpSocket: String = "") -> [String: String] {
        if isServer {
            var env: [String: String] = [
                "MYLINUX_OUT": outDir.path,
                "DISK": appsDisk,
                "DISK_SIZE_GB": String(appsSizeGB),
                "NAME": name,
                "MEM": "\(memoryGB)G",
                "SERIAL": "unix:\(serialSocket),server,nowait",
                "SSH_PORT": String(sshPort),
            ]
            if !shareDir.isEmpty { env["SHARE_DIR"] = shareDir }
            if !qmpSocket.isEmpty { env["QMP"] = qmpSocket }
            if cpus > 0 { env["CPUS"] = String(cpus) }
            let extra = CloudFolder.extraShares(cloudFolders)
            if !extra.isEmpty { env["EXTRA_SHARES"] = extra }
            return env
        }
        if kind == .omarchy {
            var env: [String: String] = [
                "MYLINUX_OUT": outDir.path,
                "DISK": appsDisk,
                "DISK_SIZE_GB": String(appsSizeGB),
                "NAME": windowName,
                "GRAB": grab,
                "MEM": "\(memoryGB)G",
                "SERIAL": "unix:\(serialSocket),server,nowait",
            ]
            if !shareDir.isEmpty { env["SHARE_DIR"] = shareDir }
            if !qmpSocket.isEmpty { env["QMP"] = qmpSocket }
            if !resolution.isEmpty { env["RES"] = resolution.lowercased() }
            if cpus > 0 { env["CPUS"] = String(cpus) }
            if !sound { env["AUDIO"] = "0" }
            if !clipboard { env["CLIPBOARD"] = "0" }
            if sshPort != 0 { env["SSH"] = "1"; env["FORWARD"] = "\(sshPort):22" }
            return env
        }
        var env: [String: String] = [
            "MYLINUX_OUT": outDir.path,
            "APPS_IMG": appsDisk,
            "APPS_SIZE_GB": String(appsSizeGB),
            "SHARE_DIR": shareDir,
            "NAME": windowName,
            "GRAB": grab,
            "MOUSE": mouse,
            "CLIPBOARD": clipboard ? "1" : "0",
            "MEM": "\(memoryGB)G",
            "SERIAL": "unix:\(serialSocket),server,nowait",
        ]
        if !resolution.isEmpty { env["RES"] = resolution.lowercased() }
        return env
    }
}

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [Profile] = [] { didSet { if loaded { save() } } }
    @Published var lastError: String?
    private var loaded = false
    private let file: URL

    init(file: URL = Paths.profilesFile, settings: AppSettings = .shared) {
        self.file = file
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Profile].self, from: data), !list.isEmpty {
            profiles = list
        } else {
            profiles = [ProfileStore.firstProfile(settings: settings)]
        }
        // every start: automatic machines get the memory this Mac suits
        for i in profiles.indices { profiles[i].applyAutomaticMemory() }
        loaded = true
        save()
    }

    /// In developer mode the first profile is the checkout's own disk and share (what ./run.sh uses), so an
    /// existing install carries over; otherwise a fresh machine folder.
    static func firstProfile(settings: AppSettings) -> Profile {
        if settings.developerMode {
            let repo = URL(fileURLWithPath: settings.repoPath, isDirectory: true)
            return Profile(name: "myLinux", appsDisk: repo.appendingPathComponent("out/apps.img").path,
                           shareDir: repo.appendingPathComponent("share", isDirectory: true).path)
        }
        return newProfile(named: "myLinux")
    }

    static func newProfile(named name: String, kind: Profile.Kind = .mylinux, folder: URL? = nil) -> Profile {
        let dir = folder ?? Paths.machines.appendingPathComponent(Paths.slug(name), isDirectory: true)
        if kind.isServer {
            var p = Profile(name: name, appsDisk: dir.appendingPathComponent("\(kind.rawValue).raw").path,
                            shareDir: dir.appendingPathComponent("Mac", isDirectory: true).path)
            p.kind = kind; p.memoryGB = Profile.recommendedMemoryGB(kind); p.appsSizeGB = 32; p.sshPort = 2223; p.clipboard = false; p.sound = false
            return p
        }
        if kind == .omarchy {
            // the share's own name is what Omarchy shows in the home folder (~/Mac)
            var p = Profile(name: name, appsDisk: dir.appendingPathComponent("omarchy.ext4").path,
                            shareDir: dir.appendingPathComponent("Mac", isDirectory: true).path)
            p.kind = .omarchy; p.memoryGB = Profile.recommendedMemoryGB(.omarchy); p.appsSizeGB = 32
            p.grab = "full"      // every key to Omarchy, Command as Super: Omarchy's shortcuts as they are meant
            return p
        }
        var p = Profile(name: name, appsDisk: dir.appendingPathComponent("apps.img").path,
                        shareDir: dir.appendingPathComponent("share", isDirectory: true).path)
        p.memoryGB = Profile.recommendedMemoryGB(.mylinux)
        return p
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// A new machine: its own disk and share, the other settings copied from `template` when given.
    @discardableResult
    func add(copying template: Profile? = nil, kind: Profile.Kind? = nil) -> Profile {
        let kind = kind ?? template?.kind ?? .mylinux
        let template = template?.kind == kind ? template : nil      // settings carry over within a kind only
        let name = uniqueName(template.map { "\($0.name) copy" } ?? (kind == .mylinux ? "Machine" : kind.title))
        var p = ProfileStore.newProfile(named: name, kind: kind)
        if let t = template {
            p.grab = t.grab; p.mouse = t.mouse; p.clipboard = t.clipboard
            p.memoryGB = t.memoryGB; p.memoryAuto = t.memoryAuto; p.resolution = t.resolution; p.appsSizeGB = t.appsSizeGB
            p.cpus = t.cpus; p.sound = t.sound      // not the SSH port: two machines cannot listen on one
        }
        // a server always listens: the next free port after the other machines'
        if kind.isServer {
            let used = Set(profiles.map(\.sshPort))
            var port = 2223
            while used.contains(port) { port += 1 }
            p.sshPort = port
        }
        // a slug already used by another profile's folder gets a suffix
        var folder = URL(fileURLWithPath: p.appsDisk).deletingLastPathComponent()
        var n = 2
        while profiles.contains(where: { $0.appsDisk == p.appsDisk || $0.shareDir == p.shareDir }) {
            folder = Paths.machines.appendingPathComponent("\(Paths.slug(name))-\(n)", isDirectory: true); n += 1
            let fresh = ProfileStore.newProfile(named: name, kind: kind, folder: folder)
            p.appsDisk = fresh.appsDisk; p.shareDir = fresh.shareDir
        }
        profiles.append(p)
        return p
    }

    func update(_ p: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }), profiles[i] != p else { return }
        profiles[i] = p
    }

    /// Removes the profile only; its disk and share stay on disk.
    func remove(_ id: UUID) { profiles.removeAll { $0.id == id } }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(profiles).write(to: file, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save profiles: \(error.localizedDescription)"
        }
    }
}
