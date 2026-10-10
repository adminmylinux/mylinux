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
          mylinux create <kind> [--name NAME] [--memory GB] [--disk GB] [--cpus N] [--ssh-port PORT] [--no-start]
                                                  [--wait [--timeout SECONDS]]
                                                  [--keys all|mac|none]  a desktop's keyboard: every key to it, ⌘ kept by the Mac, or as typed
                                                  a new machine, downloaded when needed, and started
                                                  kinds: tiny (Tiny Alpine), alpine, debian, omarchy, arch, kali, mylinux, windows
                                                  windows: --iso FILE the first time (Microsoft's Arm64 ISO);
                                                  --unattended --accept-microsoft-license [--user NAME] [--password PW]
                                                  [--edition pro|home] [--keyboard nb-NO] installs it without a question
                                                  omarchy: --unattended --password PW [--user NAME] [--keyboard Norwegian|nb-NO]
                                                  [--timezone Europe/Oslo] [--hostname NAME] [--full-name "NAME"] [--email ADDRESS]
                                                  answers its first-start questions: straight to the desktop
          mylinux start <name> [--wait [--timeout SECONDS]]   start it (downloads what it needs first)
          mylinux stop <name> [--wait]            shut it down
          mylinux restart <name>
          mylinux status <name>                   its state; "ready" is true when it can be used
          mylinux wait <name> [--timeout SECONDS] until it is ready (default 900 seconds)
          mylinux ssh <name> [-- command…]        a server's shell, or one command in it (tiny, alpine, debian)
          mylinux claude <name>                   Claude Code inside an Omarchy or a Windows machine: what is there
          mylinux claude <name> --install [--token-file FILE --token-name NAME --account WORD [--alias cc1] [--default|--not-default]]
                                                  installs what is missing (in Windows the desktop app too); with a token,
                                                  named by the file of NAME=value lines it is in and its entry there, a
                                                  subscription is added (the launcher reads the token; it is never given)
          mylinux codex <name>                    Codex inside it: what is there
          mylinux codex <name> --install [--login-from-mac] [--desktop --accept-store-terms]
                                                  installs Codex and the alias cx; signs it in with this Mac's own Codex
                                                  login; in Windows, OpenAI's desktop app from the Microsoft Store
          mylinux delete <name> --yes [--stop]    the machine and its disk, into the Trash (--stop shuts it down first)
          mylinux erase machines --yes [--stop]   every machine and its disk, into the Trash (--stop shuts running ones down first)
          mylinux erase everything --yes [--stop] as a new install: the machines, the downloads, the settings, the saved
                                                  remote passwords and macOS's permissions; the data folder goes to the
                                                  Trash and the launcher starts again
          mylinux skill install [--agent claude|codex|all]   the skill that teaches a coding agent these commands
          mylinux skill show | path
          mylinux version

        Sizes are whole gigabytes: 1, 1g, 20gb. A name with spaces goes in quotes. Every answer is JSON, but for ssh
        (the command's own output and exit status), help and skill show (text).
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
    static let valued: Set<String> = ["name", "memory", "disk", "cpus", "timeout", "iso", "agent", "ssh-port", "user", "password", "edition", "keyboard", "keys",
                                       "timezone", "hostname", "full-name", "email", "token-file", "token-name", "account", "alias"]
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
        // (a first start of a new copy is checked by macOS before it runs: that alone can take a minute)
        err("mylinux: starting myLinux Launcher…")
        for _ in 0..<120 where ask(["ping"], timeout: 1) == nil { }
        return ask(["ping"], timeout: 1) != nil
    }

    /// A download's progress line as a person would read it: the percentage when the line has one (curl's bar is
    /// drawn with # and = around it), else its words; nil when nothing is left.
    static func progress(_ line: String) -> String? {
        if let r = line.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression) { return String(line[r]) }
        let words = String(line.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 && !"#=>".unicodeScalars.contains($0) })
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return words.range(of: #"\p{L}{2}"#, options: .regularExpression) == nil ? nil : words      // (curl's "-=O=-" is no word)
    }

    /// Asks `status` until the machine is ready, has failed, or the time is up.
    static func wait(_ name: String, timeout: TimeInterval, stopped: Bool = false) -> Reply {
        let end = Date().addingTimeInterval(timeout)
        var last = Reply.failed("no answer from the launcher", code: 3)
        while true {
            if let r = ask(["status", name]) {
                last = r
                guard let m = r.json["machine"] as? [String: Any] else { return r }      // no such machine, say
                let state = m["state"] as? String ?? ""
                if stopped {
                    // (a machine that failed is not running either: what was asked for)
                    if state == "stopped" || state == "failed" { return Reply(code: 0, json: ["ok": true, "machine": m]) }
                } else {
                    if m["ready"] as? Bool == true { return r }
                    if state == "failed" || m["error"] != nil { return r.code != 0 ? r : Reply(code: 1, json: r.json.merging(["ok": false]) { _, b in b }) }
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
        guard ["kinds", "list", "create", "start", "stop", "restart", "status", "wait", "ssh", "delete", "erase", "claude", "codex"].contains(first) else {
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
        case "claude", "codex":
            // the launcher looks inside the machine, or installs there, and goes on by itself: this asks how far it
            // is until it is done (an install: 80 minutes at most unless --timeout says more; a new Windows is slow)
            guard let name = w.plain.first else { err("mylinux \(first) <name> [--install …]"); return 2 }
            guard var r = ask(args) else { return finish(.failed("no answer from the launcher", code: 3)) }
            let end = Date().addingTimeInterval(w.values["timeout"].flatMap(Double.init) ?? (w.flags.contains("install") ? 80 * 60 : 330))
            while ["checking", "working"].contains((r.json[first] as? [String: Any])?["state"] as? String ?? ""), Date() < end {
                Thread.sleep(forTimeInterval: 1.5)
                guard let next = ask([first, name, "--poll"]) else { return finish(.failed("no answer from the launcher", code: 3)) }
                r = next
            }
            if ["checking", "working"].contains((r.json[first] as? [String: Any])?["state"] as? String ?? "") {
                var j = r.json; j["ok"] = false; j["error"] = "not finished in time (it goes on inside: mylinux \(first) \"\(name)\" asks again)"
                return finish(Reply(code: 4, json: j))
            }
            return finish(r)
        case "delete":
            // --stop: the machine is shut down first and waited for; then the launcher is asked
            if w.flags.contains("stop"), w.flags.contains("yes"), let name = w.plain.first,
               let m = ask(["status", name])?.json["machine"] as? [String: Any], ["running", "starting", "downloading", "stopping"].contains(m["state"] as? String ?? "") {
                _ = ask(["stop", name])
                if wait(name, timeout: 180, stopped: true).code != 0 { return finish(.failed("\(name) did not shut down: it was not deleted")) }
            }
            guard let r = ask(args) else { return finish(.failed("no answer from the launcher", code: 3)) }
            return finish(r)
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

        /// What to do once the skill is in place.
        static let next = "Say what you want in the agent: /mylinux install tiny alpine 1gb/20gb called tester1. A session that was open before the skill was there may have to be started again to know it."
        /// Writes the skill where the agents look for theirs ("all": each agent that is on this Mac): the files written, and what went wrong.
        static func install(_ which: String = "all", text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (written: [String], problems: [String]) {
            var written: [String] = [], problems: [String] = []
            for f in folders where which == "all" || f.agent == which {
                let dir = home.appendingPathComponent(f.path, isDirectory: true)
                // "all" leaves an agent that is not on this Mac alone (its folder would be the first thing there)
                if which == "all", !FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().deletingLastPathComponent().path) { continue }
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                    written.append(dir.appendingPathComponent("SKILL.md").path)
                } catch { problems.append("\(dir.path): \(error.localizedDescription)") }
            }
            return (written, problems)
        }
        /// File › Install the Agents' Skill…: the same as `mylinux skill install`, said in a dialog.
        @MainActor static func installFromMenu() {
            let alert = NSAlert()
            // (a test's launcher, with a data folder of its own, writes into that folder, never into this Mac's agents)
            let home = ProcessInfo.processInfo.environment["MYLINUX_SUPPORT_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("home") }
                ?? FileManager.default.homeDirectoryForCurrentUser
            if let text = text() {
                let (written, problems) = install(text: text, home: home)
                if !problems.isEmpty { alert.alertStyle = .warning; alert.messageText = "The skill could not be written"; alert.informativeText = problems.joined(separator: "\n") }
                else if written.isEmpty {
                    alert.messageText = "No coding agent found on this Mac"
                    alert.informativeText = "The skill goes where Claude Code (~/.claude) and Codex (~/.codex) keep theirs, and neither folder is there. Install one of them, start it once, and choose this again."
                } else {
                    alert.messageText = "The mylinux skill is installed"
                    alert.informativeText = "Claude Code and Codex can now make, start and use machines here. " + next + "\n\n" + written.joined(separator: "\n")
                }
            } else { alert.alertStyle = .warning; alert.messageText = "This launcher has no skill file" }
            alert.runModal()
        }

        static func run(_ w: Words) -> Int32 {
            guard let text = text(), let url = bundled else { CLI.out(CLI.text(["ok": false, "error": "this app has no skill file"])); return 1 }
            switch w.plain.first ?? "show" {
            case "path": CLI.out(CLI.text(["ok": true, "path": url.path, "command": command])); return 0
            case "show": CLI.out(text); return 0
            case "install":
                let which = w.values["agent"] ?? "all"
                guard which == "all" || folders.contains(where: { $0.agent == which }) else { CLI.err("mylinux skill install --agent claude|codex|all"); return 2 }
                let (written, problems) = install(which, text: text)
                var j: [String: Any] = ["ok": problems.isEmpty && !written.isEmpty, "written": written, "command": command]
                if !problems.isEmpty { j["error"] = problems.joined(separator: "; ") }
                else if written.isEmpty { j["error"] = "neither ~/.claude nor ~/.codex is on this Mac (name one: --agent claude)" }
                else { j["next"] = Skill.next }
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
            jobs[id] = Job(phase: "starting")
            let r = RunManager.shared.runner(for: id)
            r.clearFailure()
            r.start(fresh, settings: settings, showTerminal: false)
            if case .failed(let why) = r.state { fail(why); return }
            if r.state == .stopped {
                // not started yet: macOS asks first whether the launcher may use the microphone (Runner.start), and the
                // machine starts after the answer. Said, so the wait is not a machine that stays "stopped" for no reason
                jobs[id] = Job(phase: "starting", what: "waiting for the answer to macOS's question about the microphone, on the Mac's screen")
                for _ in 0..<600 where r.state == .stopped { try? await Task.sleep(nanoseconds: 500_000_000) }
                if r.state == .stopped { fail("not started: macOS's question about the microphone was not answered (answer it on the Mac's screen, then start again)"); return }
                if case .failed(let why) = r.state { fail(why); return }
            }
            jobs[id] = nil
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
                if let m = j.manager, let progress = CLI.progress(m.progress) { job["progress"] = progress }
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
                                      "command": "\"\(CLI.Skill.command)\" ssh \"\(p.name)\" -- <command>"]
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
            let unattended = WindowsUnattended.asked(p) || WindowsUnattended.inProgress(p)
            d["windows"] = ["installed": p.windowsInstalled, "stage": ["answering Windows Setup", "installing", "first-run screens", "installed"][stage.rawValue],
                            "agent": answers, "unattended": unattended,
                            "note": p.windowsInstalled ? (unattended ? "installed: the machine restarts by itself in a moment, then it is ready" : "")
                                : unattended ? (state == "running" ? "Windows is installing itself, with nothing to answer: 15 to 40 minutes"
                                                                    : "its first start installs Windows by itself, with nothing to answer: 15 to 40 minutes")
                                             : "Windows Setup and Windows's first-run screens are answered in the machine's window, by a person"]
            ready = ready && p.windowsInstalled && answers
        }
        if p.kind == .omarchy {
            // made with its first-start answers given: ready when its desktop has been seen (OmarchyUnattended.follow)
            switch OmarchyUnattended.stage(p) {
            case .settingUp:
                d["omarchy"] = ["unattended": true, "note": state == "running" ? "Omarchy is setting itself up with the answers given: the desktop in about a minute"
                                                                                : "its first start sets Omarchy up with the answers given, without its questions"]
                ready = false
            case .asking:
                d["omarchy"] = ["unattended": false, "note": "the answers could not be put into the new disk: Omarchy asks its first-start questions in the machine's window, for a person to answer"]
            case .none: break
            }
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
        /// A machine as the answer to a question about it: its failure is the answer's own (ok false, the error, exit 1).
        func said(_ p: Profile) -> CLI.Reply {
            let d = describe(p, settings: settings)
            guard d["state"] as? String == "failed" else { return .ok(["machine": d]) }
            return CLI.Reply(code: 1, json: ["ok": false, "error": d["error"] as? String ?? "\(p.name) failed", "machine": d])
        }
        switch command {
        case "claude", "codex": return AgentCommands.handle(command, w, store: store, settings: settings)
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
            return said(p)
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
            var unattended: WindowsUnattended.Answers?, omarchy: OmarchyUnattended.Answers?
            let forOmarchy = ["timezone", "hostname", "full-name", "email"]
            if w.flags.contains("unattended"), kind == .omarchy {
                // Omarchy's first-start questions, answered beforehand: what is not said is as on this Mac
                var a = OmarchyUnattended.suggested(machine: name)
                if let user = w.values["user"] { a.user = user.trimmingCharacters(in: .whitespaces) }
                a.password = w.values["password"] ?? ""
                if let k = w.values["keyboard"] {
                    guard let layout = OmarchyUnattended.keyboard(k) else {
                        return .failed("--keyboard is one of Omarchy's keyboards by name (Norwegian, Icelandic, \"English (UK)\" …) or a language and region (nb-NO, is-IS, en-GB)", code: 2)
                    }
                    a.keyboard = layout
                }
                if let zone = w.values["timezone"] { a.timezone = zone }
                if let host = w.values["hostname"] { a.hostname = host }
                a.fullName = (w.values["full-name"] ?? "").trimmingCharacters(in: .whitespaces)
                a.email = (w.values["email"] ?? "").trimmingCharacters(in: .whitespaces)
                if w.values["edition"] != nil { return .failed("--edition is Windows's", code: 2) }
                if let problem = OmarchyUnattended.problem(a) { return .failed(problem, code: 2) }
                omarchy = a
            } else if w.flags.contains("unattended") {
                guard kind == .windows else { return .failed("--unattended is for windows and omarchy: the other kinds ask nothing", code: 2) }
                if let extra = forOmarchy.first(where: { w.values[$0] != nil }) { return .failed("--\(extra) is Omarchy's", code: 2) }
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
            } else if let alone = (["user", "password", "edition", "keyboard"] + forOmarchy).first(where: { w.values[$0] != nil }) {
                return .failed("--\(alone) goes with --unattended, for windows or omarchy (otherwise the machine asks in its window)", code: 2)
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
            // (Windows's answers wait for the first start: Runner.start writes the answer file, in the ISO's language)
            if let unattended, let problem = WindowsUnattended.keep(unattended, machineFolder: p.machineFolder) {
                _ = store.remove(p.id, trashFiles: true)
                return .failed(problem)
            }
            if let omarchy, let problem = OmarchyUnattended.write(omarchy, machineFolder: p.machineFolder) {
                _ = store.remove(p.id, trashFiles: true)
                return .failed(problem)
            }
            if !w.flags.contains("no-start") { begin(p.id, iso: w.values["iso"], store: store, settings: settings) }
            var made: [String: Any] = ["machine": describe(p, settings: settings), "created": true]
            if let a = unattended {
                made["account"] = ["user": a.user, "password": a.password.isEmpty ? "none: it signs in by itself (Settings › Accounts in Windows sets one)" : "as given",
                                   "edition": a.edition.title, "keyboard": a.keyboard]
            }
            if let a = omarchy {
                made["account"] = ["user": a.user, "password": "as given", "keyboard": a.keyboard, "timezone": a.timezone, "hostname": a.hostname,
                                   "fullName": a.fullName.isEmpty ? "not given" : a.fullName, "email": a.email.isEmpty ? "not given" : a.email]
            }
            return .ok(made)
        case "start":
            let (p, problem) = machine(); guard let p else { return problem! }
            let r = RunManager.shared.runner(for: p.id)
            if !(r.isActive || r.state == .inUseElsewhere || Runner.diskInUse(p.appsDisk)) { begin(p.id, iso: w.values["iso"], store: store, settings: settings) }
            return said(p)
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
            return said(p)
        case "delete":
            let (p, problem) = machine(); guard let p else { return problem! }
            guard w.flags.contains("yes") else { return .failed("deleting \"\(p.name)\" moves the machine and its disk to the Trash: say so with --yes", code: 2) }
            let r = RunManager.shared.runner(for: p.id)
            guard !r.isActive, r.state != .inUseElsewhere, !Runner.diskInUse(p.appsDisk) else {
                return .failed("\"\(p.name)\" is running: add --stop to shut it down first (mylinux delete \"\(p.name)\" --yes --stop). Nothing was deleted")
            }
            jobs[p.id] = nil
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
                    jobs[p.id] = nil
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
