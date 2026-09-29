import Foundation

/// myLinux Apps (server-apps/ in the repository): a Textual app inside Debian and Alpine that finds, runs and installs
/// programs from a catalog. Apps… (⇧⌘A) in a server's terminal copies its files from the public repository's main
/// branch into the machine's Mac share, and types run.sh's line into the terminal; run.sh installs the distribution's
/// Textual the first time. A change to the catalog or the app on main reaches every machine the next time Apps… opens.
enum ServerApps {
    static let files = ["run.sh", "mylinux_apps.py", "catalog.json", "speedtest.py"]
    /// Where they go in the Mac share; the share is /mnt/mac inside (run-server.sh).
    static let shareFolder = ".mylinux/apps"
    /// Typed into the terminal; the leading space keeps it out of the history. Leaving the app starts a fresh login
    /// shell, which reads the PATH run.sh keeps in ~/.profile and ~/.bashrc: what was just installed is found.
    static let command = #" MYLINUX_APPS_RELOGIN=1 sh /mnt/mac/.mylinux/apps/run.sh && exec "${SHELL:-/bin/sh}" -l"#

    static func url(_ file: String) -> URL { URL(string: "https://raw.githubusercontent.com/adminmylinux/mylinux/main/server-apps/\(file)")! }

    // ---- cloud drives: the app's "Cloud drives" rows, and its requests ------------------------------------------------
    /// What the app shows under Cloud drives, beside the app in the share: this Mac's cloud folders and the machine's.
    static func cloudStateFile(_ share: String) -> URL { URL(fileURLWithPath: share).appendingPathComponent(".mylinux/cloud.json") }
    /// Written by the app when a cloud drive is added or taken away: {"folders": [...]}. The launcher's watcher
    /// (RunManager) takes it, saves the machine's folders and restarts it to attach them.
    static func cloudRequestFile(_ share: String) -> URL { URL(fileURLWithPath: share).appendingPathComponent(".mylinux/cloud-request.json") }

    static func cloudState(_ machine: Profile) -> [String: Any] {
        ["machine": machine.name,
         // the share folder on the Mac: the speed test tells how to run it there too
         "share": machine.shareDir,
         "selected": machine.cloudFolders,
         "folders": CloudFolder.allCases.map { f in
             ["id": f.rawValue, "title": f.title, "guest": f.guestName, "onMac": f.macPath() != nil] as [String: Any]
         }]
    }

    static func writeCloudState(_ machine: Profile) {
        guard !machine.shareDir.isEmpty, let data = try? JSONSerialization.data(withJSONObject: cloudState(machine), options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = cloudStateFile(machine.shareDir)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The app's request, taken (the file is removed), or nil. Only known folder names count.
    static func takeCloudRequest(_ share: String) -> [String]? {
        let url = cloudRequestFile(share)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let folders = obj["folders"] as? [String] else { return nil }
        return CloudFolder.allCases.map(\.rawValue).filter { folders.contains($0) }
    }

    // ---- Omarchy: ⇧⌘A or Machine › Apps… in its window -----------------------------------------------------------------
    /// The app into the share, and "apps" for Omarchy's session agent (omarchy/session: it opens a terminal running
    /// it). Nil when the agent took the command, or what to tell the user. The agent is updated at the machine's
    /// start (tools/omarchy-update-session.sh), so one from an earlier launcher learns "apps" after a restart.
    static func openInOmarchy(_ machine: Profile) async -> String? {
        if let problem = await copy(to: machine.shareDir, machine: machine) { return problem }
        let control = URL(fileURLWithPath: machine.shareDir).appendingPathComponent("mylinux-tools/control", isDirectory: true)
        let cmd = control.appendingPathComponent("apps.cmd")
        do {
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            try "apps\n".write(to: cmd, atomically: true, encoding: .utf8)
        } catch {
            return "Could not leave the command for Omarchy: \(error.localizedDescription)"
        }
        // the agent looks every second, and takes (deletes) what it runs
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !FileManager.default.fileExists(atPath: cmd.path) { return nil }
        }
        try? FileManager.default.removeItem(at: cmd)
        return "Omarchy's session helper did not answer. It runs once you are signed in to Omarchy's desktop; an Omarchy made "
            + "with a launcher before 0.7.20 learns Apps… when it starts again (Machine › Restart). Meanwhile, in an Omarchy "
            + "terminal: sh /mnt/mac/.mylinux/apps/run.sh"
    }

    /// A file that is what it should be, not an error page.
    static func plausible(_ file: String, _ text: String) -> Bool {
        switch file {
        case "run.sh": return text.hasPrefix("#!") && text.contains("mylinux_apps.py")
        case "mylinux_apps.py": return text.contains("class MyLinuxApps")
        case "speedtest.py": return text.contains("def run_test")
        case "catalog.json":
            guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return obj["apps"] is [Any]
        default: return false
        }
    }

    /// The copies built into the app (Contents/Resources/server-apps), or the checkout's when run from a build.
    static func bundled() -> [String: String]? {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("server-apps"),
                    Paths.buildRepo.map { URL(fileURLWithPath: $0).appendingPathComponent("server-apps") }]
        for case let dir? in dirs {
            var texts: [String: String] = [:]
            for f in files { if let s = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8), plausible(f, s) { texts[f] = s } }
            if texts.count == files.count { return texts }
        }
        return nil
    }

    /// All of them from GitHub, or nil (one version of the app, never a mix).
    static func fromGitHub() async -> [String: String]? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        var texts: [String: String] = [:]
        for f in files {
            guard let (data, response) = try? await session.data(from: url(f)), (response as? HTTPURLResponse)?.statusCode == 200,
                  let s = String(data: data, encoding: .utf8), plausible(f, s) else { return nil }
            texts[f] = s
        }
        return texts
    }

    /// Writes the app into the share folder, with the machine's cloud drives beside it: nil when done, or what went wrong.
    static func copy(to share: String, machine: Profile?) async -> String? {
        if let machine { writeCloudState(machine) }
        return await copy(to: share)
    }

    static func copy(to share: String) async -> String? {
        guard !share.isEmpty else { return "Apps needs the machine's share folder (its page › Files & sharing)." }
        guard let texts = await fromGitHub() ?? bundled() else {
            return "GitHub couldn't be reached and the launcher has no copy of myLinux Apps."
        }
        let dir = URL(fileURLWithPath: share).appendingPathComponent(shareFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (f, s) in texts { try s.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        } catch {
            return "Could not write myLinux Apps into \(dir.path): \(error.localizedDescription)"
        }
        return nil
    }
}
