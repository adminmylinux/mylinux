import AppKit

/// myLinux Launcher from the command line: `mylinux` (a small script in the app, Contents/Resources/bin/mylinux,
/// which runs the launcher's own binary with --cli). Made for coding agents as much as for people: a person tells an
/// agent "install a tiny alpine, 1 GB and 20 GB, called tester1", the agent's skill (skills/mylinux/SKILL.md, which
/// `mylinux skill install` puts where Claude Code and Codex look) turns that into
///
///     mylinux create tiny --name tester1 --memory 1 --disk 20 --wait
///
/// and what comes back is JSON: the machine, its state, and for a server the ssh command that reaches it.
///
/// The command is a client. The launcher that is running owns the machines (their settings, their downloads, their
/// QEMUs), so every word goes to it as a distributed notification, scoped to the launcher's data folder as the
/// machines' own requests are (MachineLink), and its answer comes back the same way. A launcher that is not running
/// is started first. What takes time (a download, a first start, Windows installing itself) is not waited for by the
/// launcher: `create` and `start` answer at once, the machine's `status` says where it is (`job`), and `--wait` and
/// `wait` ask again until it is `ready`.
enum CLI {
    static let request = Notification.Name("dev.mylinux.cli.request")
    static let reply = Notification.Name("dev.mylinux.cli.reply")
    static var scope: String { Paths.support.path }

    struct Reply {
        var code: Int32 = 0
        var json: [String: Any] = [:]
        static func failed(_ why: String, code: Int32 = 1) -> Reply { Reply(code: code, json: ["ok": false, "error": why]) }
        static func ok(_ json: [String: Any]) -> Reply { Reply(code: 0, json: json.merging(["ok": true]) { a, _ in a }) }
    }

    static let usage = """
        mylinux: myLinux Launcher from the command line. Every answer is JSON.

          mylinux kinds                           the kinds of machine, and whether each is downloaded
          mylinux list                            every machine and its state
          mylinux create <kind> [--name NAME] [--memory GB] [--disk GB] [--cpus N] [--ssh-port PORT] [--no-start] [--wait]
                                                  [--keys all|mac|none]  a desktop's keyboard: every key to it, ⌘ kept by the Mac, or as typed
                                                  a new machine, downloaded when needed, and started
                                                  kinds: tiny (Tiny Alpine), alpine, debian, omarchy, arch, kali, mylinux, windows
                                                  windows: --iso FILE the first time (Microsoft's Arm64 ISO);
                                                  --unattended --accept-microsoft-license [--user NAME] [--password PW]
                                                  [--edition pro|home] [--keyboard nb-NO] installs it without a question
          mylinux start <name> [--wait]           start it (downloads what it needs first)
          mylinux stop <name> [--wait]            shut it down
          mylinux restart <name>
          mylinux status <name>                   its state; "ready" is true when it can be used
          mylinux wait <name> [--timeout SECONDS] until it is ready (default 900 seconds)
          mylinux ssh <name> [-- command…]        a server's shell, or one command in it (tiny, alpine, debian)
          mylinux delete <name> --yes             the machine and its disk, into the Trash
          mylinux erase machines --yes [--stop]   every machine and its disk, into the Trash (--stop shuts running ones down first)
          mylinux erase everything --yes [--stop] as a new install: the machines, the downloads, the settings, the saved
                                                  remote passwords and macOS's permissions; the data folder goes to the
                                                  Trash and the launcher starts again
          mylinux skill install [--agent claude|codex|all]   the skill that teaches a coding agent these commands
          mylinux skill show | path
          mylinux version

        Sizes are whole gigabytes: 1, 1g, 20gb. A name with spaces goes in quotes.
        """

    // ---- words -------------------------------------------------------------------------------------------------------
    static let kindWords: [String: Profile.Kind] = [
        "tiny": .tiny, "tinyalpine": .tiny, "tiny-alpine": .tiny, "tiny_alpine": .tiny,
        "alpine": .alpine, "debian": .debian, "omarchy": .omarchy, "arch": .arch, "archlinux": .arch, "arch-linux": .arch,
        "kali": .kali, "kalilinux": .kali, "kali-linux": .kali, "windows": .windows, "windows11": .windows, "win11": .windows, "win": .windows,
        "mylinux": .mylinux,
    ]
    static func kind(_ word: String) -> Profile.Kind? { kindWords[word.lowercased().replacingOccurrences(of: " ", with: "")] }

    /// "1", "1g", "1gb", "20GB", "2048m": whole gigabytes, or nil.
    static func gigabytes(_ word: String) -> Int? {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        for (suffix, per) in [("gib", 1.0), ("gb", 1.0), ("g", 1.0), ("mib", 1024.0), ("mb", 1024.0), ("m", 1024.0), ("", 1.0)] where w.hasSuffix(suffix) {
            guard let n = Double(w.dropLast(suffix.count)), n > 0 else { return nil }
            let gb = n / per
            return gb == gb.rounded() && gb >= 1 ? Int(gb) : nil
        }
        return nil
    }

    /// The words of a command: what stands alone, what follows a --name, the --flags, and everything after "--".
    struct Words: Equatable {
        var plain: [String] = [], values: [String: String] = [:], flags: Set<String> = [], rest: [String] = []
    }
    static let valued: Set<String> = ["name", "memory", "disk", "cpus", "timeout", "iso", "agent", "ssh-port", "user", "password", "edition", "keyboard", "keys"]
    static func words(_ args: [String]) -> Words? {
        var w = Words(), i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { w.rest = Array(args[(i + 1)...]); break }
            if a.hasPrefix("--") {
                var name = String(a.dropFirst(2)), value: String?
                if let eq = name.firstIndex(of: "=") { value = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
                if valued.contains(name) {
                    if value == nil { i += 1; guard i < args.count else { return nil }; value = args[i] }
                    w.values[name] = value
                } else { guard value == nil else { return nil }; w.flags.insert(name) }
            } else { w.plain.append(a) }
            i += 1
        }
        return w
    }

    static func text(_ json: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // ---- the command (the client) ------------------------------------------------------------------------------------
    static func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// One request to the launcher and its answer; nil when nobody answered in `timeout` seconds.
    static func ask(_ argv: [String], timeout: TimeInterval = 20) -> Reply? {
        let id = UUID().uuidString
        var answer: Reply?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: reply, object: scope, queue: .main) { n in
            guard let info = n.userInfo, info["id"] as? String == id else { return }
            let json = (info["json"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            answer = Reply(code: Int32(info["code"] as? Int ?? 1), json: json)
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(request, object: scope, userInfo: ["id": id, "argv": argv], deliverImmediately: true)
        let end = Date().addingTimeInterval(timeout)
        while answer == nil, Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return answer
    }

    /// The launcher answers; it is started first when it is not running (not a test's, with a data folder of its own).
    static func reach() -> Bool {
        if ask(["ping"], timeout: 1.5) != nil { return true }
        guard ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"] == nil else { return false }
        let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", Bundle.main.bundlePath]
        guard (try? open.run()) != nil else { return false }
        open.waitUntilExit()
        for _ in 0..<30 where ask(["ping"], timeout: 1) == nil { }
        return ask(["ping"], timeout: 1) != nil
    }

    /// Asks `status` until the machine is ready, has failed, or the time is up.
    static func wait(_ name: String, timeout: TimeInterval, stopped: Bool = false) -> Reply {
        let end = Date().addingTimeInterval(timeout)
        var last = Reply.failed("no answer from the launcher", code: 3)
        while true {
            if let r = ask(["status", name]) {
                last = r
                guard r.code == 0, let m = r.json["machine"] as? [String: Any] else { return r }
                let state = m["state"] as? String ?? ""
                if stopped { if state == "stopped" || state == "failed" { return r } }
                else {
                    if m["ready"] as? Bool == true { return r }
                    if state == "failed" || m["error"] != nil { return Reply(code: 1, json: r.json.merging(["ok": false]) { _, b in b }) }
                }
            }
            if Date() >= end {
                var j = last.json; j["ok"] = false; j["error"] = "not \(stopped ? "stopped" : "ready") after \(Int(timeout)) seconds (it goes on: ask status, or wait again)"
                return Reply(code: 4, json: j)
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    static func run(_ args: [String]) -> Int32 {
        guard let first = args.first, !["help", "--help", "-h"].contains(first) else { out(usage); return 0 }
        if first == "version" || first == "--version" {
            out(text(["ok": true, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0", "app": Bundle.main.bundlePath])); return 0
        }
        guard let w = words(Array(args.dropFirst())) else { err("mylinux: a --word is missing its value (mylinux help)"); return 2 }
        if first == "skill" { return Skill.run(w) }
        guard ["kinds", "list", "create", "start", "stop", "restart", "status", "wait", "ssh", "delete", "erase"].contains(first) else {
            err("mylinux: no command \"\(first)\" (mylinux help)"); return 2
        }
        guard reach() else {
            out(text(["ok": false, "error": "myLinux Launcher is not running and could not be started"])); return 3
        }
        func finish(_ r: Reply) -> Int32 { out(text(r.json)); return r.code }
        let timeout = w.values["timeout"].flatMap(Double.init) ?? 900
        switch first {
        case "wait":
            guard let name = w.plain.first else { err("mylinux wait <name>"); return 2 }
            return finish(wait(name, timeout: timeout))
        case "ssh":
            guard let name = w.plain.first else { err("mylinux ssh <name> [-- command…]"); return 2 }
            guard let r = ask(["status", name]) else { return finish(.failed("no answer from the launcher", code: 3)) }
            guard r.code == 0, let m = r.json["machine"] as? [String: Any] else { return finish(r) }
            guard let ssh = m["ssh"] as? [String: Any], let argv = ssh["argv"] as? [String] else {
                return finish(.failed("\(name) has no SSH (a server has: tiny, alpine, debian)"))
            }
            guard m["state"] as? String == "running" else { return finish(.failed("\(name) is not running: mylinux start \"\(name)\" --wait")) }
            // the user's ssh takes this process's place: its output and its exit status are the command's
            let all = ["/usr/bin/ssh"] + argv + w.rest
            var c = all.map { strdup($0) } + [nil]
            execv("/usr/bin/ssh", &c)
            return finish(.failed("ssh could not be started"))
        case "erase":
            // --stop: what runs is shut down first, one machine at a time, and waited for; then the launcher is asked
            if w.flags.contains("stop"), w.flags.contains("yes"), let machines = ask(["list"])?.json["machines"] as? [[String: Any]] {
                for m in machines where ["running", "starting", "downloading"].contains(m["state"] as? String ?? "") {
                    guard let name = m["name"] as? String else { continue }
                    _ = ask(["stop", name])
                    let stopped = wait(name, timeout: 180, stopped: true)
                    if stopped.code != 0 { return finish(.failed("\(name) did not shut down: nothing was erased")) }
                }
            }
            guard let r = ask(args) else { return finish(.failed("no answer from the launcher", code: 3)) }
            return finish(r)
        default:
            guard let r = ask(args) else { return finish(.failed("no answer from the launcher", code: 3)) }
            guard r.code == 0, w.flags.contains("wait"), ["create", "start", "stop"].contains(first),
                  let name = (r.json["machine"] as? [String: Any])?["name"] as? String else { return finish(r) }
            return finish(wait(name, timeout: timeout, stopped: first == "stop"))
        }
    }

    /// The skill file for coding agents, and where each agent keeps its skills.
    enum Skill {
        static let folders: [(agent: String, path: String)] = [("claude", ".claude/skills/mylinux"), ("codex", ".codex/skills/mylinux")]
        static var bundled: URL? {
            let dirs = [Bundle.main.resourceURL?.appendingPathComponent("skills/mylinux"),
                        Paths.buildRepo.map { URL(fileURLWithPath: $0).appendingPathComponent("skills/mylinux") }]
            return dirs.compactMap { $0?.appendingPathComponent("SKILL.md") }.first { FileManager.default.isReadableFile(atPath: $0.path) }
        }
        /// The command's own path, as the skill names it: this app's script, wherever the app is.
        static var command: String { Bundle.main.resourceURL?.appendingPathComponent("bin/mylinux").path ?? "mylinux" }
        /// The file as an agent gets it: the place of the command written in.
        static func text() -> String? {
            guard let url = bundled, let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return s.replacingOccurrences(of: "{{MYLINUX}}", with: command)
        }

        /// At the launcher's start: a skill that was installed is made the same as this launcher's (a newer launcher's
        /// commands, the app moved to another folder). Never put where there is none.
        static func refreshInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            guard let text = text() else { return }
            for f in folders {
                let file = home.appendingPathComponent(f.path, isDirectory: true).appendingPathComponent("SKILL.md")
                guard let have = try? String(contentsOf: file, encoding: .utf8), have != text else { continue }
                try? text.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        static func run(_ w: Words) -> Int32 {
            guard let text = text(), let url = bundled else { CLI.out(CLI.text(["ok": false, "error": "this app has no skill file"])); return 1 }
            switch w.plain.first ?? "show" {
            case "path": CLI.out(CLI.text(["ok": true, "path": url.path, "command": command])); return 0
            case "show": CLI.out(text); return 0
            case "install":
                let which = w.values["agent"] ?? "all"
                let chosen = folders.filter { which == "all" || $0.agent == which }
                guard !chosen.isEmpty else { CLI.err("mylinux skill install --agent claude|codex|all"); return 2 }
                let home = FileManager.default.homeDirectoryForCurrentUser
                var written: [String] = [], problems: [String] = []
                for f in chosen {
                    let dir = home.appendingPathComponent(f.path, isDirectory: true)
                    // "all" leaves an agent that is not on this Mac alone (its folder would be the first thing there)
                    if which == "all", !FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().deletingLastPathComponent().path) { continue }
                    do {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                        written.append(dir.appendingPathComponent("SKILL.md").path)
                    } catch { problems.append("\(dir.path): \(error.localizedDescription)") }
                }
                var j: [String: Any] = ["ok": problems.isEmpty && !written.isEmpty, "written": written, "command": command]
                if !problems.isEmpty { j["error"] = problems.joined(separator: "; ") }
                else if written.isEmpty { j["error"] = "neither ~/.claude nor ~/.codex is on this Mac (name one: --agent claude)" }
                else { j["next"] = "Start a new session of the agent, then say what you want: /mylinux install tiny alpine 1gb/20gb called tester1" }
                CLI.out(CLI.text(j)); return problems.isEmpty && !written.isEmpty ? 0 : 1
            default: CLI.err("mylinux skill install | show | path"); return 2
            }
        }
    }
}

/// The launcher's side: what the command asks, done with the launcher's own store, downloaders and runners.
@MainActor enum CLIService {
    /// What is being done for a machine on the command line's word: a download, then its start.
    struct Job { var phase: String; var what = ""; var manager: ScriptDownloader?; var error: String? }
    private(set) static var jobs: [UUID: Job] = [:]
    /// A Windows install that answers itself, asked for and not begun: its answers, until the ISO is there to say its language.
    private static var answers: [UUID: WindowsUnattended.Answers] = [:]
    private static var observer: NSObjectProtocol?

    static func serve() {
        guard !MachineApp.active, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: CLI.request, object: CLI.scope, queue: .main) { n in
            guard let info = n.userInfo, let id = info["id"] as? String, let argv = info["argv"] as? [String] else { return }
            MainActor.assumeIsolated {
                let r = handle(argv)
                DistributedNotificationCenter.default().postNotificationName(CLI.reply, object: CLI.scope,
                    userInfo: ["id": id, "code": Int(r.code), "json": CLI.text(r.json)], deliverImmediately: true)
            }
        }
    }

    static func find(_ name: String, store: ProfileStore = .shared) -> Profile? {
        store.profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? store.profiles.first { $0.id.uuidString.lowercased() == name.lowercased() }
    }

    /// What a kind needs downloaded before a machine of it can start, in order; or why it cannot be got.
    static func needs(_ p: Profile, settings: AppSettings = .shared) -> (list: [(name: String, manager: ScriptDownloader, start: () -> Void)], problem: String?) {
        var list: [(name: String, manager: ScriptDownloader, start: () -> Void)] = []
        let fm = FileManager.default
        let runtime: (name: String, manager: ScriptDownloader, start: () -> Void) = ("the accelerated QEMU", RuntimeManager.shared, { RuntimeManager.shared.download(settings) })
        if p.isServer {
            let created = fm.fileExists(atPath: p.appsDisk) && fm.fileExists(atPath: p.machineFolder.appendingPathComponent(p.kind.firstStartFile).path)
            if p.kind == .tiny, !settings.runtimeHasMke2fs { list.append(runtime) }
            if !created, !settings.serverImagePresent(p.kind) {
                let m = ServerImageManager.shared(p.kind)
                list.append((p.kind.title, m, { m.download(settings) }))
            }
        } else if p.kind.runsDesktop {
            if !settings.runtimePresent { list.append(runtime) }
            if p.kind == .windows {
                if !p.windowsInstalled, !settings.desktopPresent(.windows) {
                    return (list, "Windows is Microsoft's and is not downloaded by myLinux: get the “Windows 11 (multi-edition ISO for Arm64)” from \(DesktopImageManager.microsoftPage.absoluteString), then: mylinux start \"\(p.name)\" --iso <the file>")
                }
            } else if !p.desktopCreated, !settings.desktopPresent(p.kind) {
                let m = DesktopImageManager.shared(p.kind)
                list.append((p.kind.title, m, { m.download(settings) }))
            }
        } else if !settings.imagePresent {
            if settings.developerMode { return (list, "no myLinux image in \(settings.outDir.path): run ./build.sh or tools/get-image.sh in the checkout") }
            list.append(("myLinux", ImageManager.shared, { ImageManager.shared.download(settings) }))
        }
        return (list, nil)
    }

    /// Downloads what the machine needs, then starts it. Answers at once; `status` follows it.
    static func begin(_ id: UUID, iso: String? = nil, store: ProfileStore = .shared, settings: AppSettings = .shared) {
        if let j = jobs[id], j.error == nil { return }                     // already on its way
        jobs[id] = Job(phase: "preparing")
        Task { @MainActor in
            @MainActor func fail(_ why: String) { jobs[id] = Job(phase: "failed", error: why) }
            @MainActor func settle(_ m: ScriptDownloader) async { while m.busy { try? await Task.sleep(nanoseconds: 300_000_000) } }
            guard let p = store.profiles.first(where: { $0.id == id }) else { jobs[id] = nil; return }
            if p.kind == .windows, let iso {
                let m = DesktopImageManager.windows
                await settle(m)
                jobs[id] = Job(phase: "downloading", what: "Windows's drivers (the ISO is checked and kept)", manager: m)
                m.run("tools/get-windows.sh", arguments: ["--iso", iso], starting: "Checking the ISO and fetching the drivers…", settings: settings)
                await settle(m)
                if let e = m.lastError { fail(e); return }
            }
            for _ in 0..<4 {                                               // (each round: what is still missing)
                let n = needs(p, settings: settings)
                guard let need = n.list.first else { if let problem = n.problem { fail(problem); return }; break }
                await settle(need.manager)                                 // one begun in the launcher's window counts
                if needs(p, settings: settings).list.first?.name != need.name { continue }
                jobs[id] = Job(phase: "downloading", what: need.name, manager: need.manager)
                need.manager.quiet = true
                need.start()
                await settle(need.manager)
                need.manager.quiet = false
                if let e = need.manager.lastError { fail("\(need.name) did not download: \(e)"); return }
            }
            let left = needs(p, settings: settings)
            if let missing = left.list.first { fail("\(missing.name) did not download"); return }
            if let problem = left.problem { fail(problem); return }
            guard let fresh = store.profiles.first(where: { $0.id == id }) else { jobs[id] = nil; return }
            if var a = answers[id], !fresh.windowsInstalled {
                a.language = WindowsUnattended.language(isoLabel: settings.windowsISO)
                if let problem = WindowsUnattended.write(a, machineFolder: fresh.machineFolder) { fail(problem); return }
                answers[id] = nil
            }
            jobs[id] = Job(phase: "starting")
            let r = RunManager.shared.runner(for: id)
            r.clearFailure()
            r.start(fresh, settings: settings, showTerminal: false)
            if case .failed(let why) = r.state { fail(why) } else { jobs[id] = nil }
        }
    }

    static func describe(_ p: Profile, settings: AppSettings = .shared) -> [String: Any] {
        let r = RunManager.shared.runner(for: p.id)
        var d: [String: Any] = ["name": p.name, "id": p.id.uuidString.lowercased(), "kind": p.kind.rawValue, "title": p.kind.title,
                                "memoryGB": p.memoryGB, "diskGB": p.appsSizeGB, "cpus": p.cpus == 0 ? "automatic" : "\(p.cpus)",
                                "folder": p.machineFolder.path]
        if p.memoryAuto { d["memory"] = "automatic: follows this Mac's memory" }
        var state = "stopped", failed = false
        switch r.state {
        case .stopped: state = Runner.diskInUse(p.appsDisk) ? "running" : "stopped"
        case .starting: state = "starting"
        case .running, .inUseElsewhere: state = "running"
        case .stopping: state = "stopping"
        case .failed(let why): state = "failed"; failed = true; d["error"] = why
        }
        if let j = jobs[p.id] {
            if let e = j.error { d["error"] = e; state = "failed"; failed = true }
            else {
                var job: [String: Any] = ["phase": j.phase]
                if !j.what.isEmpty { job["what"] = j.what }
                if let m = j.manager, !m.progress.isEmpty { job["progress"] = m.progress }
                d["job"] = job
                if state == "stopped" { state = j.phase == "starting" ? "starting" : "downloading" }
            }
        }
        d["state"] = state
        var ready = !failed && state == "running"
        if p.sshPort != 0 {
            let t = p.terminalProfile
            let argv = SshTerminal.arguments(for: t)
            var ssh: [String: Any] = ["host": "127.0.0.1", "port": p.sshPort, "user": t.username, "key": t.keyFile, "argv": argv,
                                      "command": "mylinux ssh \"\(p.name)\" -- <command>"]
            if p.isServer {
                // a server this launcher did not start itself (taken over from the launcher before it, or started
                // while this one was not running) has not been asked yet whether its SSH answers: asked now, once,
                // and without a terminal. Otherwise it would run, answer, and never be "ready".
                if state == "running", !r.sshReady, !r.waitingForSSH { r.openTerminal(p, show: false) }
                ssh["ready"] = r.sshReady; ready = ready && r.sshReady
            }
            d["ssh"] = ssh
        }
        if p.kind == .windows {
            let stage = WindowsSetupStage.of(p)
            let answers = WindowsDisplay.keptMemory(p.machineFolder) != nil
            let unattended = WindowsUnattended.inProgress(p) || CLIService.answers[p.id] != nil
            d["windows"] = ["installed": p.windowsInstalled, "stage": ["answering Windows Setup", "installing", "first-run screens", "installed"][stage.rawValue],
                            "agent": answers, "unattended": unattended,
                            "note": p.windowsInstalled ? (unattended ? "installed: the machine restarts by itself in a moment, then it is ready" : "")
                                : unattended ? "Windows is installing itself, with nothing to answer: 15 to 40 minutes"
                                             : "Windows Setup and Windows's first-run screens are answered in the machine's window, by a person"]
            ready = ready && p.windowsInstalled && answers
        }
        d["ready"] = ready
        return d
    }

    static func handle(_ argv: [String], store: ProfileStore = .shared, settings: AppSettings = .shared) -> CLI.Reply {
        guard let command = argv.first, let w = CLI.words(Array(argv.dropFirst())) else { return .failed("not a command", code: 2) }
        func machine() -> (Profile?, CLI.Reply?) {
            guard let name = w.plain.first else { return (nil, .failed("which machine? mylinux \(command) <name>", code: 2)) }
            guard let p = find(name, store: store) else {
                return (nil, .failed("no machine named \"\(name)\" (there are: \(store.profiles.map(\.name).joined(separator: ", ")))"))
            }
            return (p, nil)
        }
        switch command {
        case "ping": return .ok(["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"])
        case "kinds":
            let kinds: [Profile.Kind] = [.tiny, .alpine, .debian, .omarchy, .arch, .kali, .mylinux, .windows]
            return .ok(["kinds": kinds.map { k -> [String: Any] in
                let p = ProfileStore.newProfile(named: "x", kind: k)
                let downloaded = k.isServer ? settings.serverImagePresent(k) : k.runsDesktop ? settings.desktopPresent(k) : settings.imagePresent
                let size = k.isServer ? ServerImageManager.shared(k).size : k.runsDesktop ? DesktopImageManager.shared(k).size : "about 120 MB"
                var d: [String: Any] = ["kind": k.rawValue, "title": k.title, "what": k.isServer ? "a server: a shell over SSH, no desktop" : "a desktop in a window",
                                        "downloaded": downloaded, "download": size, "defaultMemoryGB": p.memoryGB, "defaultDiskGB": p.appsSizeGB,
                                        "smallestDiskGB": k == .windows ? 32 : k == .mylinux ? 4 : 8, "ssh": k.isServer]
                if k == .windows { d["note"] = "Microsoft's ISO is the user's to download; Windows Setup and its first-run screens are answered by a person in the machine's window" }
                return d
            }])
        case "list": return .ok(["machines": store.profiles.map { describe($0, settings: settings) }])
        case "status":
            let (p, problem) = machine(); guard let p else { return problem! }
            return .ok(["machine": describe(p, settings: settings)])
        case "create":
            guard let word = w.plain.first, let kind = CLI.kind(word) else {
                return .failed("which kind? tiny, alpine, debian, omarchy, arch, kali, mylinux or windows (mylinux kinds)", code: 2)
            }
            var name = store.uniqueName(kind == .mylinux ? "Machine" : kind.title)
            if let given = w.values["name"]?.trimmingCharacters(in: .whitespaces) {
                guard !given.isEmpty, given.count <= 60, !given.contains("/"), !given.contains(",") else { return .failed("a name is up to 60 characters, without / or ,", code: 2) }
                guard find(given, store: store) == nil else { return .failed("a machine named \"\(given)\" is there already (mylinux status \"\(given)\")") }
                name = given
            }
            var memory: Int?, disk: Int?, cpus: Int?
            if let m = w.values["memory"] { guard let v = CLI.gigabytes(m), v <= 512 else { return .failed("--memory is whole gigabytes: 1, 2, 4 …", code: 2) }; memory = v }
            if let s = w.values["disk"] { guard let v = CLI.gigabytes(s) else { return .failed("--disk is whole gigabytes: 20, 32, 64 …", code: 2) }; disk = v }
            if let c = w.values["cpus"] { guard let v = Int(c), v >= 0 else { return .failed("--cpus is a number of cores", code: 2) }; cpus = v }
            var grab: String?
            if let k = w.values["keys"] {
                guard !kind.isServer, let g = ["all": "full", "mac": "opt", "none": "none"][k.lowercased()] else { return .failed("--keys is all, mac or none, for a desktop", code: 2) }
                grab = g
            }
            var port: Int?
            if let s = w.values["ssh-port"] {
                guard let v = Int(s), (1024...65535).contains(v) else { return .failed("--ssh-port is 1024 to 65535", code: 2) }
                if let other = store.profiles.first(where: { $0.sshPort == v }) { return .failed("port \(v) is \(other.name)'s") }
                port = v
            }
            if let m = memory, m > Profile.macMemoryGB { return .failed("this Mac has \(Profile.macMemoryGB) GB of memory") }
            // the settings are checked before anything is made
            var unattended: WindowsUnattended.Answers?
            if w.flags.contains("unattended") {
                guard kind == .windows else { return .failed("--unattended is for windows: the other kinds ask nothing", code: 2) }
                guard w.flags.contains("accept-microsoft-license") || w.flags.contains("accept-microsoft-licence") else {
                    return .failed("an unattended install answers Windows Setup for the user, Microsoft's licence terms among its questions (\(WindowsUnattended.licenseTerms)). That acceptance is the user's: when they have said so, add --accept-microsoft-license", code: 2)
                }
                let user = (w.values["user"] ?? NSUserName()).trimmingCharacters(in: .whitespaces), password = w.values["password"] ?? ""
                if let problem = WindowsUnattended.problem(user: user, password: password) { return .failed(problem, code: 2) }
                var a = WindowsUnattended.Answers(user: user, password: password)
                if let e = w.values["edition"] { guard let edition = WindowsUnattended.Edition(rawValue: e.lowercased()) else { return .failed("--edition is pro or home", code: 2) }; a.edition = edition }
                if let k = w.values["keyboard"] { guard WindowsUnattended.isLocale(k) else { return .failed("--keyboard is a language and region as Windows writes them: nb-NO, en-US, de-DE …", code: 2) }; a.keyboard = k }
                else if let k = WindowsUnattended.keyboard(layout: WindowsUnattended.macLayout()) { a.keyboard = k }
                a.computer = WindowsUnattended.computerName(name)
                guard settings.desktopPresent(.windows) || w.values["iso"] != nil else {
                    return .failed("Windows is Microsoft's and is not downloaded by myLinux: get the “Windows 11 (multi-edition ISO for Arm64)” from \(DesktopImageManager.microsoftPage.absoluteString) and pass it with --iso <the file>")
                }
                unattended = a
            } else if ["user", "password", "edition", "keyboard"].contains(where: { w.values[$0] != nil }) {
                return .failed("--user, --password, --edition and --keyboard go with --unattended (otherwise Windows Setup asks for them in the machine's window)", code: 2)
            }
            var draft = ProfileStore.newProfile(named: name, kind: kind)
            if let memory { draft.memoryGB = memory; draft.memoryAuto = false }
            if let disk { draft.appsSizeGB = disk }
            if let cpus { draft.cpus = cpus }
            if let problem = draft.problems.first { return .failed(problem) }
            var p = store.add(kind: kind, named: name)
            p.memoryGB = draft.memoryGB; p.memoryAuto = draft.memoryAuto; p.appsSizeGB = draft.appsSizeGB; p.cpus = draft.cpus
            if let port { p.sshPort = port }                    // (a server gets the next free one by itself)
            if let grab { p.grab = grab }
            store.update(p)
            if let unattended { answers[p.id] = unattended }
            if !w.flags.contains("no-start") { begin(p.id, iso: w.values["iso"], store: store, settings: settings) }
            var made: [String: Any] = ["machine": describe(p, settings: settings), "created": true]
            if let a = unattended {
                made["account"] = ["user": a.user, "password": a.password.isEmpty ? "none: it signs in by itself (Settings › Accounts in Windows sets one)" : "as given",
                                   "edition": a.edition.title, "keyboard": a.keyboard]
            }
            return .ok(made)
        case "start":
            let (p, problem) = machine(); guard let p else { return problem! }
            let r = RunManager.shared.runner(for: p.id)
            if !(r.isActive || r.state == .inUseElsewhere || Runner.diskInUse(p.appsDisk)) { begin(p.id, iso: w.values["iso"], store: store, settings: settings) }
            return .ok(["machine": describe(p, settings: settings)])
        case "stop":
            let (p, problem) = machine(); guard let p else { return problem! }
            let r = RunManager.shared.runner(for: p.id)
            if let j = jobs[p.id], j.error != nil { jobs[p.id] = nil }
            if r.isActive || r.canStopElsewhere { r.stop() }
            return .ok(["machine": describe(p, settings: settings)])
        case "restart":
            let (p, problem) = machine(); guard let p else { return problem! }
            let r = RunManager.shared.runner(for: p.id)
            if r.isActive || r.canStopElsewhere { r.restart(p) } else { begin(p.id, store: store, settings: settings) }
            return .ok(["machine": describe(p, settings: settings)])
        case "delete":
            let (p, problem) = machine(); guard let p else { return problem! }
            guard w.flags.contains("yes") else { return .failed("deleting \"\(p.name)\" moves the machine and its disk to the Trash: say so with --yes", code: 2) }
            let r = RunManager.shared.runner(for: p.id)
            guard !r.isActive, r.state != .inUseElsewhere, !Runner.diskInUse(p.appsDisk) else { return .failed("\"\(p.name)\" is running: mylinux stop \"\(p.name)\" --wait, then delete") }
            jobs[p.id] = nil; answers[p.id] = nil
            if let left = store.remove(p.id, trashFiles: true) { return .ok(["deleted": p.name, "note": left]) }
            return .ok(["deleted": p.name, "note": "the machine's files are in the Trash"])
        case "erase":
            guard let what = w.plain.first, ["machines", "everything"].contains(what) else {
                return .failed("erase what? mylinux erase machines --yes (every machine and its disk, into the Trash), or mylinux erase everything --yes (as a new install)", code: 2)
            }
            let names = store.profiles.map(\.name)
            let going = what == "machines"
                ? "every machine and its disk (\(names.isEmpty ? "there are none" : names.joined(separator: ", "))), into the Trash"
                : "everything the launcher keeps on this Mac: the machines and their disks (\(names.isEmpty ? "none" : names.joined(separator: ", "))), the downloaded systems and QEMU, the settings, the saved remote passwords and macOS's permissions for it. The data folder goes to the Trash, and the launcher starts again as on a new Mac"
            guard w.flags.contains("yes") else { return .failed("this erases \(going). Say so with --yes", code: 2) }
            let running = store.profiles.filter { p in
                let r = RunManager.shared.runner(for: p.id)
                return r.isActive || r.state == .inUseElsewhere || Runner.diskInUse(p.appsDisk) || (jobs[p.id].map { $0.error == nil } ?? false)
            }
            guard running.isEmpty else {
                return .failed("\(running.map(\.name).joined(separator: ", ")) \(running.count == 1 ? "is" : "are") running: shut \(running.count == 1 ? "it" : "them") down first, or add --stop. Nothing was erased")
            }
            if what == "machines" {
                var notes: [String] = []
                for p in store.profiles {
                    jobs[p.id] = nil; answers[p.id] = nil
                    if let left = store.remove(p.id, trashFiles: true) { notes.append(left) }
                }
                return .ok(["erased": names, "note": notes.isEmpty ? "the machines' files are in the Trash; the downloaded systems are kept, so a new machine needs no download"
                                                                   : "not everything could be moved to the Trash: " + notes.joined(separator: "; ")])
            }
            // everything: after this answer has gone out (the launcher quits to do it)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let problem = StartOver.clearAll(toTrash: true) { NSLog("erase everything: %@", problem) }
            }
            return .ok(["erased": "everything", "machines": names,
                        "note": "the launcher's data folder is in the Trash (put it back to undo; empty the Trash to free its space); the settings, saved remote passwords and macOS's permissions are reset, and the launcher starts again as on a new Mac. Saved downloads outside that folder are kept"])
        default: return .failed("no command \"\(command)\"", code: 2)
        }
    }
}
