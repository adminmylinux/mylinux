import AppKit
import SwiftUI

/// Each machine is an app of its own in the Dock and ⌘Tab, named after the machine and with its kind's icon.
/// A desktop (myLinux, Omarchy) is its QEMU, which tools/make-app-bundle.sh puts in a bundle of its own. A server
/// (Debian, Alpine) is its terminal window: the launcher builds <out>/machines/<id>/<name>.app around an APFS clone
/// of its own binary, signed ad hoc, with the launcher's Frameworks and Resources linked in, and opens it. That
/// app (machine mode: its Info.plist names the machine) shows only the machine's terminal windows; the machine
/// itself stays the launcher's, which reports its state to the app (the seconds, a restart) and takes the app's
/// requests (MachineLink). Quitting the app leaves the machine running; kept in the Dock, it starts the machine.
enum MachineApp {
    static let idKey = "MyLinuxMachineID"
    static let launcherKey = "MyLinuxLauncher"
    static let launcherBundleID = "dev.mylinux.launcher"

    /// In a machine's own app: the machine it is (nil in the launcher).
    static let machineID: UUID? = (Bundle.main.object(forInfoDictionaryKey: idKey) as? String).flatMap(UUID.init(uuidString:))
    static var active: Bool { machineID != nil }

    /// The bundle identifier of a machine's own app.
    static func bundleID(_ p: Profile) -> String {
        let id = p.id.uuidString.lowercased()
        switch p.kind {
        case .mylinux: return "dev.mylinux.vm.\(id)"
        case .omarchy: return "dev.mylinux.vm.omarchy.\(id)"
        case .debian, .alpine: return "dev.mylinux.machine.\(id)"
        }
    }

    static func running(_ p: Profile) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(p)).first { !$0.isTerminated }
    }

    // ---- a server's app, built by the launcher ---------------------------------------------------------------------
    /// <out>/machines/<id>/<name>.app, the folder make-app-bundle.sh uses for the desktops.
    static func bundleURL(_ p: Profile, outDir: URL = AppSettings.shared.outDir) -> URL {
        outDir.appendingPathComponent("machines/\(p.id.uuidString.lowercased())/\(appName(p)).app", isDirectory: true)
    }
    /// The name in the Dock and ⌘Tab: the machine's, without what a file name cannot hold.
    static func appName(_ p: Profile) -> String {
        var n = p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while n.hasPrefix(".") { n.removeFirst() }
        n = n.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? p.kind.title : n
    }

    /// Builds the server's app, or refreshes it when the launcher, the name or the icon changed since. Nil when the
    /// launcher is not an app bundle (a bare `swift build` binary) or the bundle could not be made: the terminal
    /// then opens in the launcher, as before.
    static func prepare(_ p: Profile) -> URL? {
        guard p.isServer, !active else { return nil }
        let launcher = Bundle.main.bundleURL
        guard launcher.pathExtension == "app", let exe = Bundle.main.executableURL,
              let resources = Bundle.main.resourceURL else { return nil }
        let fm = FileManager.default
        let url = bundleURL(p)
        let dir = url.deletingLastPathComponent()
        let icon = resources.appendingPathComponent("runtime/tools/icons/machine-\(p.kind.rawValue).icns")
        let exeAttrs = (try? fm.attributesOfItem(atPath: exe.path)) ?? [:]
        let stamp = [launcher.path, "\(exeAttrs[.size] ?? 0)", "\((exeAttrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
                     appName(p), "\((try? fm.attributesOfItem(atPath: icon.path)[.size]) ?? 0)"].joined(separator: "|")
        let stampFile = url.appendingPathComponent("Contents/Resources/.mylinux-stamp")
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp { return url }
        if running(p) != nil, fm.fileExists(atPath: url.path) { return url }       // in use: refreshed next time
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let new = dir.appendingPathComponent(".new.app", isDirectory: true)
            try? fm.removeItem(at: new)
            let contents = new.appendingPathComponent("Contents", isDirectory: true)
            let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
            let res = contents.appendingPathComponent("Resources", isDirectory: true)
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)
            try fm.createDirectory(at: res, withIntermediateDirectories: true)
            // the binary: a clone (no disk space), without the launcher's extended attributes (a quarantine flag
            // would have Gatekeeper judge this new app), signed ad hoc outside the bundle so codesign signs just the
            // file; no hardened runtime, so the launcher's Developer ID libraries load beside it
            let tmp = dir.appendingPathComponent(".exe.tmp")
            try? fm.removeItem(at: tmp)
            guard Runner.run("/bin/cp", ["-c", "-X", exe.path, tmp.path]) == 0 || Runner.run("/bin/cp", ["-X", exe.path, tmp.path]) == 0,
                  Runner.run("/usr/bin/codesign", ["--force", "--sign", "-", tmp.path]) == 0 else {
                NSLog("machine app: could not copy or sign the launcher binary"); try? fm.removeItem(at: tmp); return nil
            }
            // a clone keeps the quarantine flag of a downloaded launcher even with -X
            removexattr(tmp.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            try fm.moveItem(at: tmp, to: macos.appendingPathComponent("myLinux Machine"))
            let frameworks = launcher.appendingPathComponent("Contents/Frameworks")
            if fm.fileExists(atPath: frameworks.path) {
                try fm.createSymbolicLink(at: contents.appendingPathComponent("Frameworks"), withDestinationURL: frameworks)
            }
            for item in (try? fm.contentsOfDirectory(atPath: resources.path)) ?? [] where !item.hasSuffix(".icns") && !item.hasPrefix(".") {
                try fm.createSymbolicLink(at: res.appendingPathComponent(item), withDestinationURL: resources.appendingPathComponent(item))
            }
            if fm.fileExists(atPath: icon.path) { try fm.copyItem(at: icon, to: res.appendingPathComponent("machine.icns")) }
            let info: [String: Any] = [
                "CFBundleName": appName(p), "CFBundleDisplayName": appName(p),
                "CFBundleExecutable": "myLinux Machine", "CFBundleIdentifier": bundleID(p),
                "CFBundleIconFile": "machine", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                "LSMinimumSystemVersion": "15.0", "NSHighResolutionCapable": true,
                idKey: p.id.uuidString, launcherKey: launcher.path,
            ]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            try stamp.write(to: new.appendingPathComponent("Contents/Resources/.mylinux-stamp"), atomically: true, encoding: .utf8)
            // the bundle under an old name (a renamed machine) goes, and this one takes its place
            for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where old.pathExtension == "app" && old.lastPathComponent != ".new.app" {
                try? fm.removeItem(at: old)
            }
            _ = Runner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", new.path])
            try fm.moveItem(at: new, to: url)
            LSRegisterURL(url as CFURL, true)
            return url
        } catch {
            NSLog("machine app: could not make %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    /// Opens a server's terminal in its own app, or brings the running app forward (reconnecting a window left
    /// disconnected). False when there is no such app to open: the caller opens the window in the launcher.
    @discardableResult
    static func show(_ p: Profile) -> Bool {
        guard !active, ProcessInfo.processInfo.environment["MYLINUX_MACHINE_APPS"] != "0" else { return false }
        if let app = running(p) {
            MachineLink.post(MachineLink.show, ["id": p.id.uuidString])
            app.activate()
            return true
        }
        guard let url = prepare(p) else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = ["--connect"]
        cfg.createsNewApplicationInstance = false
        cfg.addsToRecentItems = false
        // the tests' data folder and terminal choice go along
        cfg.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("MYLINUX_") }
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            guard let error else { return }
            NSLog("machine app: could not open %@: %@; the terminal opens in the launcher", url.path, error.localizedDescription)
            DispatchQueue.main.async { RemoteWindowController.show(p.terminalProfile) }
        }
        return true
    }

    // ---- machine mode: this process is a machine's own app ---------------------------------------------------------
    private static var startingWindow: NSWindow?
    private static var sawRunning = false
    private static var stoppedSince: Date?

    static var profile: Profile? { machineID.flatMap { id in ProfileStore.shared.profiles.first { $0.id == id } } }
    static var runner: Runner? { machineID.map { RunManager.shared.runner(for: $0) } }

    /// At launch in machine mode. From the launcher (--connect) the machine answers ssh already: the terminal
    /// opens at once. From the Dock or Finder, the launcher is asked to start the machine (and opened for that
    /// when it is not running), with the seconds counting in a small window until the terminal opens.
    static func run() {
        guard let id = machineID else { return }
        NSApp.setActivationPolicy(.regular)
        note("started as \(Bundle.main.bundleIdentifier ?? "?") \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        MachineLink.follow(id)
        if CommandLine.arguments.contains("--connect") { showTerminal() }
        else { showStarting(); MachineLink.request(["action": "open"]) }
    }

    static func showTerminal() {
        ProfileStore.shared.reload()
        guard let p = profile else { NSLog("machine app: machine %@ is not in the launcher's list", machineID?.uuidString ?? "?"); NSApp.terminate(nil); return }
        let c = RemoteWindowController.show(p.terminalProfile)
        startingWindow?.close(); startingWindow = nil
        NSApp.activate()
        note("terminal shown for \(p.name)")
        // MYLINUX_TEST_RESTART_CLOUD=dropbox (a test): save cloud folders as the Cloud tab does, from this app
        if let cloud = ProcessInfo.processInfo.environment["MYLINUX_TEST_RESTART_CLOUD"], !testRestarted, let r = runner {
            testRestarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                var q = p; q.cloudFolders = cloud.split(separator: ",").map(String.init); ProfileStore.shared.update(q)
                MachineLink.request(["action": "cloudFolders", "folders": q.cloudFolders, "restart": r.isActive])
                r.mirrorRestartAsked(); c.testShowRestartProgress()
                note("restart asked for \(cloud); running: \(r.isActive)")
            }
        }
    }
    private static var testRestarted = false

    /// NSLog, and a line in MYLINUX_TEST_LOG when a test asks for one (this app's output goes nowhere else).
    static func note(_ s: String) {
        NSLog("machine app: %@", s)
        guard let path = ProcessInfo.processInfo.environment["MYLINUX_TEST_LOG"] else { return }
        let line = Data("\(Date().timeIntervalSince1970) \(s)\n".utf8)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: line) }
    }

    /// The Dock icon clicked with no window open: the terminal again.
    static func reopen() {
        if RemoteWindowController.open.isEmpty, startingWindow == nil {
            if runner?.isActive == true { showTerminal() } else { showStarting(); MachineLink.request(["action": "open"]) }
        }
    }

    private static func showStarting() {
        guard startingWindow == nil, let p = profile, let r = runner else { return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: MachineStartingView(runner: r, name: p.name, kind: p.kind)))
        w.styleMask = [.titled, .closable]
        w.title = p.name
        w.isReleasedWhenClosed = false
        w.center(); w.makeKeyAndOrderFront(nil)
        startingWindow = w
        NSApp.activate()
    }

    /// Each report from the launcher: once the machine has run and then stays stopped (shut down from the
    /// launcher, not a restart), its app has nothing left to show and quits.
    static func noteState(_ r: Runner) {
        if r.isActive { sawRunning = true; stoppedSince = nil; return }
        guard sawRunning, r.state == .stopped else { return }
        if let b = r.restartBeganAt, (r.readyAt ?? .distantPast) < b { return }       // restarting
        let since = stoppedSince ?? Date(); stoppedSince = since
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard stoppedSince == since, runner?.state == .stopped else { return }
            NSLog("machine app: the machine was shut down; quitting")
            NSApp.terminate(nil)
        }
    }
}

/// Between the launcher and the machines' own apps: distributed notifications, scoped to one data folder (a
/// test's MYLINUX_SUPPORT_DIR never reaches the user's machines).
enum MachineLink {
    /// launcher → app: the machine's state (Runner.report); open or reconnect the terminal
    static let report = Notification.Name("dev.mylinux.machine.report")
    static let show = Notification.Name("dev.mylinux.machine.show")
    /// app → launcher: "hello" (report now), "open" (start it, or open its terminal), "cloudFolders" (save, restart)
    static let request = Notification.Name("dev.mylinux.machine.request")

    private static var scope: String { Paths.support.path }
    private static var observers: [NSObjectProtocol] = []

    static func post(_ name: Notification.Name, _ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: scope, userInfo: info, deliverImmediately: true)
    }

    // ---- in the launcher ----
    static func serve() {
        guard !MachineApp.active, observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: request, object: scope, queue: .main) { n in
            guard let info = n.userInfo, let id = (info["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let p = ProfileStore.shared.profiles.first(where: { $0.id == id }) else { return }
            let r = RunManager.shared.runner(for: id)
            switch info["action"] as? String {
            case "hello": send(r, force: true)
            case "open": send(r, force: true); QuickStart.start(p)
            case "cloudFolders":
                var q = p
                q.cloudFolders = (info["folders"] as? [String]) ?? []
                ProfileStore.shared.update(q)
                if info["restart"] as? Bool == true, r.isActive || r.state == .inUseElsewhere { r.restart(q) }
            default: break
            }
        })
    }

    private static var sent: [UUID: NSDictionary] = [:]
    /// The runner's state to its app, when it changed (the console's text is not part of it).
    static func send(_ r: Runner, force: Bool = false) {
        guard !MachineApp.active else { return }
        let info = r.report
        if !force, sent[r.profileID] == info as NSDictionary { return }
        sent[r.profileID] = info as NSDictionary
        post(report, info)
    }

    // ---- in a machine's app ----
    private static var heard = false
    private static var pending: [[String: Any]] = []
    private static var launcherOpened = false

    static func follow(_ id: UUID) {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: report, object: scope, queue: .main) { n in
            guard let info = n.userInfo, info["id"] as? String == id.uuidString, let r = MachineApp.runner else { return }
            let wasReady = r.readyIn
            r.mirror(info)
            if r.readyIn != wasReady { RemoteWindowController.open.forEach { $0.sshStatus() } }
            MachineApp.note("report: \(info["state"] as? String ?? "?")\(r.readyIn.map { " ready in " + Runner.seconds($0) } ?? "")")
            if !heard { heard = true; pending.forEach(send); pending = [] }
            MachineApp.noteState(r)
        })
        observers.append(center.addObserver(forName: show, object: scope, queue: .main) { n in
            guard n.userInfo?["id"] as? String == id.uuidString else { return }
            MachineApp.showTerminal()
        })
        hello(id, tries: 0)
    }

    /// "hello" until the launcher answers; after a second and a half without an answer the launcher is opened
    /// (in the background), and the requests made meanwhile go once it answers.
    private static func hello(_ id: UUID, tries: Int) {
        guard !heard else { return }
        post(request, ["id": id.uuidString, "action": "hello"])
        if tries == 3, !launcherOpened { openLauncher() }
        guard tries < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { hello(id, tries: tries + 1) }
    }

    private static func openLauncher() {
        launcherOpened = true
        guard ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] == nil else { return }    // never from a test
        let path = Bundle.main.object(forInfoDictionaryKey: MachineApp.launcherKey) as? String
        let url = path.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: MachineApp.launcherBundleID)
        guard let url else { NSLog("machine app: myLinux Launcher was not found"); return }
        NSLog("machine app: opening myLinux Launcher (%@)", url.path)
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    static func request(_ info: [String: Any]) {
        guard let id = MachineApp.machineID else { return }
        var info = info; info["id"] = id.uuidString
        if heard { send(info) } else { pending.append(info) }
    }
    private static func send(_ info: [String: Any]) { post(request, info) }
}

/// A machine's own app opened from the Dock: the machine starting, in seconds, until its terminal opens.
struct MachineStartingView: View {
    @ObservedObject var runner: Runner
    let name: String
    let kind: Profile.Kind
    private let opened = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 16) {
                if let icon = NSImage(named: "machine") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if case .failed(let why) = runner.state {
                        Text("\(name) did not start").font(.headline)
                        Text(why).font(.callout).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Starting \(name)…").font(.headline)
                        Text(Runner.seconds(ctx.date.timeIntervalSince(runner.startedAt ?? opened)))
                            .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(width: 360)
        }
    }
}
