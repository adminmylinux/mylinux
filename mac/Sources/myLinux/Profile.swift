import Foundation

/// One saved way to start myLinux: keyboard and mouse handling, machine size, and which apps disk and share
/// folder it uses (separate disks are separate myLinux installs). Maps onto run.sh's environment.
struct Profile: Codable, Identifiable, Hashable {
    /// What runs in the machine. myLinux is run.sh: the RAM-resident image plus an apps disk. Omarchy is
    /// run-omarchy.sh: the Try Omarchy guest on the accelerated QEMU runtime, where `appsDisk` is the machine's root
    /// disk (its kernel and initramfs sit in boot/ beside it) and `appsSizeGB` the size that disk is created with.
    /// Debian is run-debian.sh: a terminal-only Debian server from the cloud image, `appsDisk` its root disk, no
    /// window; the launcher reaches it through the serial console and an SSH terminal on `sshPort`.
    enum Kind: String, Codable { case mylinux, omarchy, debian }
    var isServer: Bool { kind == .debian }

    var id = UUID()
    var kind = Kind.mylinux
    var name = "myLinux"
    var grab = "opt"            // GRAB: opt | full | none
    var mouse = "tablet"        // MOUSE: tablet | relative
    var clipboard = true        // CLIPBOARD
    var memoryGB = 6            // MEM
    var resolution = ""         // RES: "" fits the screen the pointer is on, else WxH
    var appsSizeGB = 16         // APPS_SIZE_GB, used when the disk is created
    var appsDisk = ""           // APPS_IMG
    var shareDir = ""           // SHARE_DIR
    // Omarchy machines only (run-omarchy.sh)
    var cpus = 0                // CPUS: 0 lets the script choose from the Mac's core count
    var sound = true            // AUDIO
    var sshPort = 0             // SSH=1 and FORWARD=<port>:22 when not 0: ssh -p <port> <user>@127.0.0.1 from the Mac

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
    }

    /// The QEMU window title and run.sh instance name. The first profile keeps the plain name.
    var windowName: String {
        if kind != .mylinux { return name }
        return name == "myLinux" ? "myLinux" : "myLinux (\(name))"
    }
    /// The script that starts this kind of machine, relative to the scripts folder.
    var script: String { kind == .omarchy ? "run-omarchy.sh" : kind == .debian ? "run-debian.sh" : "run.sh" }
    /// The Debian machine's folder (its disk, SSH key, console password and seed live there).
    var machineFolder: URL { URL(fileURLWithPath: appsDisk).deletingLastPathComponent() }

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
        if kind == .debian {
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
        if kind == .debian {
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
        if kind == .debian {
            var p = Profile(name: name, appsDisk: dir.appendingPathComponent("debian.raw").path,
                            shareDir: dir.appendingPathComponent("Mac", isDirectory: true).path)
            p.kind = .debian; p.memoryGB = 4; p.appsSizeGB = 32; p.sshPort = 2223; p.clipboard = false; p.sound = false
            return p
        }
        if kind == .omarchy {
            // the share's own name is what Omarchy shows in the home folder (~/Mac)
            var p = Profile(name: name, appsDisk: dir.appendingPathComponent("omarchy.ext4").path,
                            shareDir: dir.appendingPathComponent("Mac", isDirectory: true).path)
            p.kind = .omarchy; p.memoryGB = 8; p.appsSizeGB = 32
            return p
        }
        return Profile(name: name, appsDisk: dir.appendingPathComponent("apps.img").path,
                       shareDir: dir.appendingPathComponent("share", isDirectory: true).path)
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
        let name = uniqueName(template.map { "\($0.name) copy" } ?? (kind == .omarchy ? "Omarchy" : kind == .debian ? "Debian" : "Machine"))
        var p = ProfileStore.newProfile(named: name, kind: kind)
        if let t = template {
            p.grab = t.grab; p.mouse = t.mouse; p.clipboard = t.clipboard
            p.memoryGB = t.memoryGB; p.resolution = t.resolution; p.appsSizeGB = t.appsSizeGB
            p.cpus = t.cpus; p.sound = t.sound      // not the SSH port: two machines cannot listen on one
        }
        // a Debian machine always listens: the next free port after the other machines'
        if kind == .debian {
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
