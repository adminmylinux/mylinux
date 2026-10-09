import Foundation

/// One saved way to start myLinux: keyboard and mouse handling, machine size, and which apps disk and share
/// folder it uses (separate disks are separate myLinux installs). Maps onto run.sh's environment.
struct Profile: Codable, Identifiable, Hashable {
    /// What runs in the machine. myLinux is run.sh: the RAM-resident image plus an apps disk. Omarchy is
    /// run-omarchy.sh: the Try Omarchy guest on the accelerated QEMU runtime, where `appsDisk` is the machine's root
    /// disk (its kernel and initramfs sit in boot/ beside it) and `appsSizeGB` the size that disk is created with.
    /// Debian and Alpine are servers (run-debian.sh, run-alpine.sh, both run-server.sh): terminal-only machines from
    /// the distribution's cloud image, `appsDisk` their root disk, no window; the launcher reaches them through the
    /// serial console and an SSH terminal on `sshPort`. Arch is a desktop like Omarchy (run-omarchy.sh with
    /// DESKTOP=arch): Arch Linux ARM with KDE Plasma, built by tools/build-arch-image.sh. Kali is the third desktop
    /// there (DESKTOP=kali): Kali Linux with its Xfce desktop, built by tools/build-kali-image.sh from Kali's packages. Tiny is a third server
    /// (run-tiny.sh): Tiny Alpine, Alpine's mini root filesystem on myLinux's kernel, no cloud image and no firmware.
    /// Windows (run-windows.sh) is Windows 11 for Arm, installed by Microsoft's own Setup from the ISO the user downloaded:
    /// a desktop in the same window as the others, `appsDisk` its disk, no share folder (Windows reads no 9p).
    enum Kind: String, Codable {
        case mylinux, omarchy, debian, alpine, arch, tiny, kali, windows
        var isServer: Bool { self == .debian || self == .alpine || self == .tiny }
        /// A desktop on the QEMU runtime: Omarchy, Arch with Plasma and Kali (run-omarchy.sh), and Windows (run-windows.sh).
        var runsDesktop: Bool { self == .omarchy || self == .arch || self == .kali || self == .windows }
        var title: String {
            switch self { case .mylinux: return "myLinux"; case .omarchy: return "Omarchy"; case .debian: return "Debian"; case .alpine: return "Alpine"; case .arch: return "Arch Linux"; case .tiny: return "Tiny Alpine"; case .kali: return "Kali Linux"; case .windows: return "Windows" }
        }
        /// A server's account inside: "debian" (bash, sudo) or Alpine's own "alpine" (ash until the install script, doas).
        /// Tiny Alpine is Alpine: the same account, install script and snippets.
        var serverUser: String { self == .tiny ? "alpine" : rawValue }
        /// What Install Script… loads for a server: debian_install.sh, alpine_install.sh (Tiny Alpine's too).
        var installScriptName: String { "\(serverUser)_install.sh" }
        /// Whose snippets a machine is offered (snippets.json's "os").
        var snippetOS: String { self == .tiny ? "alpine" : rawValue }
        /// What a server's first start leaves in its folder beside the disk: the cloud-init seed, or Tiny Alpine's kernel.
        var firstStartFile: String { self == .tiny ? "boot/Image" : "seed.iso" }
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
    var cloudFolders: [String] = []   // CloudFolder raw values, shared inside as ~/Dropbox and so on (EXTRA_SHARES)
    var macFolders: [MacFolder] = []  // Mac folders of the user's choosing, shared the same way as ~/<name> (EXTRA_SHARES)

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
        macFolders = try c.decodeIfPresent([MacFolder].self, forKey: .macFolders) ?? []
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
        case .omarchy, .arch, .kali, .windows: return [4, 6, 8][tier]
        case .debian: return [2, 2, 4][tier]
        case .alpine, .tiny: return [2, 2, 4][tier]      // idles in 60 MB (Tiny in 40); Claude Code and Codex's server need the room
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
    var script: String { kind == .windows ? "run-windows.sh" : kind.runsDesktop ? "run-omarchy.sh" : kind.isServer ? "run-\(kind.rawValue).sh" : "run.sh" }
    /// A desktop machine that has been started before: its disk and what its first start put beside it (a Linux
    /// desktop's kernel, a Windows machine's firmware settings). Only a new one needs the download.
    var desktopCreated: Bool {
        let beside = machineFolder.appendingPathComponent(kind == .windows ? "vars.fd" : "boot/vmlinuz-linux").path
        return FileManager.default.fileExists(atPath: appsDisk) && FileManager.default.fileExists(atPath: beside)
    }
    /// Windows is installed in this machine: its own setup script said so (setup.log, through a virtio port), and
    /// run-windows.sh keeps the word as a file from the next start on. Until then a start is Windows Setup, at the
    /// installer's 1024x768.
    var windowsInstalled: Bool {
        guard kind == .windows else { return false }
        if FileManager.default.fileExists(atPath: machineFolder.appendingPathComponent("installed").path) { return true }
        guard let log = try? String(contentsOf: machineFolder.appendingPathComponent("setup.log"), encoding: .utf8) else { return false }
        return log.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("mylinux-setup: installed") }
    }
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
        if kind.runsDesktop {
            if appsDisk.isEmpty { p.append("Choose where the machine's disk lives.") }
            if !((kind == .windows ? 32 : 8)...2000).contains(appsSizeGB) { p.append("Disk size must be \(kind == .windows ? 32 : 8)–2000 GB.") }
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
            let extra = CloudFolder.extraShares(cloudFolders, mac: macFolders)
            if !extra.isEmpty { env["EXTRA_SHARES"] = extra }
            return env
        }
        if kind.runsDesktop {
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
            if kind != .omarchy && kind != .windows { env["DESKTOP"] = kind.rawValue }      // arch, kali
            let extra = CloudFolder.extraShares(cloudFolders, mac: macFolders)
            if !extra.isEmpty { env["EXTRA_SHARES"] = extra }
            env.merge(appBundleEnvironment) { $1 }
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
        let extra = CloudFolder.extraShares(cloudFolders, mac: macFolders)
        if !extra.isEmpty { env["EXTRA_SHARES"] = extra }
        env.merge(appBundleEnvironment) { $1 }
        return env
    }

    /// A desktop machine's own app (tools/make-app-bundle.sh): named after the machine, with its kind's icon, so each
    /// machine is an app of its own in the Dock and ⌘Tab. The icon path is relative to the scripts folder.
    var appBundleEnvironment: [String: String] {
        var env = ["APP_ID": id.uuidString.lowercased(), "APP_NAME": name]
        if kind.runsDesktop { env["APP_ICON"] = "tools/icons/machine-\(kind.rawValue).icns" }
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
        if let data = try? Data(contentsOf: file), let list = ProfileStore.decodeList(data) {
            profiles = list
        } else if settings.developerMode {
            profiles = [ProfileStore.firstProfile(settings: settings)]
        }
        // otherwise none: a new install starts empty, and the welcome offers the machines (nothing is made unasked)
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
        if kind == .windows {
            // no share folder: Windows reads no 9p. Every key to it, Command as the Windows key and Option as Alt, as
            // on a PC keyboard; 64 GB is what Windows 11 asks for (the file grows as it fills)
            var p = Profile(name: name, appsDisk: dir.appendingPathComponent("windows.raw").path, shareDir: "")
            p.kind = kind; p.memoryGB = Profile.recommendedMemoryGB(kind); p.appsSizeGB = 64; p.grab = "full"
            return p
        }
        if kind.runsDesktop {
            // the share's own name is what Omarchy shows in the home folder (~/Mac); Arch mounts it at ~/Mac too
            var p = Profile(name: name, appsDisk: dir.appendingPathComponent("\(kind.rawValue).ext4").path,
                            shareDir: dir.appendingPathComponent("Mac", isDirectory: true).path)
            p.kind = kind; p.memoryGB = Profile.recommendedMemoryGB(kind); p.appsSizeGB = 32
            // Omarchy: every key to it, Command as Super, its shortcuts as they are meant. Plasma is a Ctrl desktop:
            // ⌘ stays with the Mac, Option is its Meta key
            p.grab = kind == .omarchy ? "full" : "opt"
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
        // a slug already used by another profile's folder, or left on disk by a removed machine (its disk would boot
        // again as the "new" machine), gets a suffix
        var folder = URL(fileURLWithPath: p.appsDisk).deletingLastPathComponent()
        var n = 2
        while profiles.contains(where: { $0.appsDisk == p.appsDisk || $0.shareDir == p.shareDir })
                || ProfileStore.leftOver(URL(fileURLWithPath: p.appsDisk).deletingLastPathComponent()) {
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

    /// Removes the profile; with `trashFiles`, also its disk and share (machineFiles), into the Trash.
    /// Returns what could not be moved to the Trash, in words; nil when everything went.
    @discardableResult
    func remove(_ id: UUID, trashFiles: Bool = false) -> String? {
        let p = profiles.first { $0.id == id }
        profiles.removeAll { $0.id == id }
        // the machine's own app (MachineApp, make-app-bundle.sh) goes with it
        try? FileManager.default.removeItem(at: AppSettings.shared.outDir.appendingPathComponent("machines/\(id.uuidString.lowercased())"))
        guard trashFiles, let p else { return nil }
        var failed: [String] = []
        for url in machineFiles(p) {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { failed.append("\(url.path): \(error.localizedDescription)") }
        }
        return failed.isEmpty ? nil : failed.joined(separator: "\n")
    }

    /// What goes to the Trash with a machine: its own folder under machines/ (disk, share, kernel, keys) when no other
    /// machine uses it; else (a folder chosen by hand, a checkout's out/apps.img) only its disk, never a shared folder.
    func machineFiles(_ p: Profile, machinesRoot: URL = Paths.machines) -> [URL] {
        let fm = FileManager.default
        let disk = URL(fileURLWithPath: p.appsDisk), folder = disk.deletingLastPathComponent().standardizedFileURL
        let others = profiles.filter { $0.id != p.id }
        let inMachines = folder.deletingLastPathComponent().path == machinesRoot.standardizedFileURL.path
        let folderShared = others.contains { URL(fileURLWithPath: $0.appsDisk).deletingLastPathComponent().standardizedFileURL == folder
            || URL(fileURLWithPath: $0.shareDir).standardizedFileURL.path.hasPrefix(folder.path + "/") }
        if inMachines && !folderShared { return fm.fileExists(atPath: folder.path) ? [folder] : [] }
        let diskShared = others.contains { $0.appsDisk == p.appsDisk }
        return !diskShared && fm.fileExists(atPath: disk.path) ? [disk] : []
    }

    /// A folder under machines/ that a removed machine left behind (its disk, or a share with files in it).
    static func leftOver(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        return items.contains { !$0.hasPrefix(".") }
    }

    /// Kinds the launcher had once and has no more: Puppy Linux (0.7.54 only, emulated and too slow to keep).
    static let retiredKinds: Set<String> = ["puppy"]
    /// The saved list without the machines of retired kinds. An unknown kind otherwise opens as myLinux, which would
    /// take a Puppy machine's disk for an apps disk; such a machine is left out instead, its folder stays on disk.
    static func decodeList(_ data: Data) -> [Profile]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              raw.contains(where: { retiredKinds.contains($0["kind"] as? String ?? "") }),
              let kept = try? JSONSerialization.data(withJSONObject: raw.filter { !retiredKinds.contains($0["kind"] as? String ?? "") })
        else { return try? JSONDecoder().decode([Profile].self, from: data) }
        return try? JSONDecoder().decode([Profile].self, from: kept)
    }

    /// A machine's own app (MachineApp) reads the list but never writes it: the launcher keeps it.
    static var readOnly: Bool { MachineApp.active }

    /// The list as saved now (a machine's own app, after the launcher changed it).
    func reload() {
        guard let data = try? Data(contentsOf: file), let list = ProfileStore.decodeList(data), !list.isEmpty else { return }
        loaded = false; profiles = list; loaded = true
    }

    private func save() {
        // a launcher handing over to a newer one writes nothing more: the data is the new one's (it may have been
        // cleared meanwhile, and an old copy would bring its machines back)
        guard !ProfileStore.readOnly, !Handover.handingOver else { return }
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
