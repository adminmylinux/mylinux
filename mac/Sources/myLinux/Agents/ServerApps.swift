import Foundation

/// myLinux Apps (server-apps/ in the repository): a Textual app inside Debian and Alpine that finds, runs and installs
/// programs from a catalog. Apps… (⇧⌘A) in a server's terminal copies its files from the public repository's main
/// branch into the machine's Mac share, and types run.sh's line into the terminal; run.sh installs the distribution's
/// Textual the first time. A change to the catalog or the app on main reaches every machine the next time Apps… opens.
enum ServerApps {
    static let files = ["run.sh", "mylinux_apps.py", "catalog.json"]
    /// Where they go in the Mac share; the share is /mnt/mac inside (run-server.sh).
    static let shareFolder = ".mylinux/apps"
    /// Typed into the terminal; the leading space keeps it out of the history.
    static let command = " sh /mnt/mac/.mylinux/apps/run.sh"

    static func url(_ file: String) -> URL { InstallScript.url("server-apps/\(file)") }

    /// A file that is what it should be, not an error page.
    static func plausible(_ file: String, _ text: String) -> Bool {
        switch file {
        case "run.sh": return text.hasPrefix("#!") && text.contains("mylinux_apps.py")
        case "mylinux_apps.py": return text.contains("class MyLinuxApps")
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

    /// All three from GitHub, or nil (one version of the app, never a mix).
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

    /// Writes the app into the share folder: nil when done, or what went wrong.
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
