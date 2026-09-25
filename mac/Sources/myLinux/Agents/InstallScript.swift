import Foundation

/// What "Install Script…" in a server's terminal runs: <distro>_install.sh (debian_install.sh, alpine_install.sh) from
/// the public repo, so it can change without a new launcher (a copy built into the app stands in when GitHub can't be reached). A line of the form
/// `NAME=1   # option: Label` is a checkbox in the dialog; ticking it rewrites that line in the text, and editing the
/// line by hand moves the checkbox, so the text is always exactly what runs.
enum InstallScript {
    static let defaultFile = "debian_install.sh"
    static func url(_ file: String) -> URL { URL(string: "https://raw.githubusercontent.com/adminmylinux/mylinux/main/\(file)")! }
    /// Where it lands in the machine before the terminal runs it.
    static let guestDir = "~/.local/share/mylinux"
    static func guestPath(_ file: String) -> String { guestDir + "/" + file }

    struct Option: Equatable, Identifiable {
        let name: String
        let label: String
        let on: Bool
        var id: String { name }
    }

    private static let optionLine = try! NSRegularExpression(
        pattern: #"^([A-Za-z_][A-Za-z0-9_]*)=([01])([ \t]+#[ \t]*option:[ \t]*(.*?))[ \t]*$"#, options: [.anchorsMatchLines])

    /// The script's checkboxes, in the order they appear.
    static func options(in script: String) -> [Option] {
        let ns = script as NSString
        var seen = Set<String>()
        return optionLine.matches(in: script, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = ns.substring(with: m.range(at: 1))
            guard seen.insert(name).inserted else { return nil }
            let label = ns.substring(with: m.range(at: 4))
            return Option(name: name, label: label.isEmpty ? name : label, on: ns.substring(with: m.range(at: 2)) == "1")
        }
    }

    /// The script with one option's line switched on or off; the rest of the text is untouched.
    static func setting(_ name: String, to on: Bool, in script: String) -> String {
        let ns = script as NSString
        guard let m = optionLine.matches(in: script, range: NSRange(location: 0, length: ns.length))
                .first(where: { ns.substring(with: $0.range(at: 1)) == name }) else { return script }
        return ns.replacingCharacters(in: m.range(at: 2), with: on ? "1" : "0")
    }

    /// Something that looks like a shell script, not an error page.
    static func plausible(_ text: String) -> Bool { text.hasPrefix("#!") && text.utf8.count < 1_000_000 }

    /// The copy built into the app (Contents/Resources), or the checkout's when run from a build folder.
    static func bundled(_ file: String) -> String? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(file),
                          Paths.buildRepo.map { URL(fileURLWithPath: $0).appendingPathComponent(file) }]
        for case let url? in candidates { if let s = try? String(contentsOf: url, encoding: .utf8), plausible(s) { return s } }
        return nil
    }

    /// The line typed into the terminal: run the uploaded script with the shell its #! line names (Alpine's is sh:
    /// bash is what it installs), then a fresh bash login, which reads the new aliases (and on Alpine is the new login
    /// shell). The login follows even when the script stopped early, as long as there is a bash. The leading space
    /// keeps it out of the history.
    static func command(file: String, script: String) -> String {
        let first = script.prefix(while: { $0 != "\n" })
        return " \(first.contains("bash") ? "bash" : "sh") \(guestPath(file)); command -v bash >/dev/null && exec bash -l\n"
    }
}

/// Loads the script from GitHub, falling back to the bundled copy.
@MainActor
final class InstallScriptLoader: ObservableObject {
    enum State: Equatable { case loading, loaded(fromGitHub: Bool), failed(String) }
    @Published private(set) var state = State.loading
    @Published var text = ""

    let file: String
    /// With text already in hand (a picture of the dialog), as if it had come from GitHub, and nothing to load.
    init(file: String, preset: String? = nil) {
        self.file = file
        if let preset { text = preset; state = .loaded(fromGitHub: true) }
    }

    func load() async {
        state = .loading
        var request = URLRequest(url: InstallScript.url(file), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("myLinux-Launcher", forHTTPHeaderField: "User-Agent")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let s = String(data: data, encoding: .utf8), InstallScript.plausible(s) {
            text = s; state = .loaded(fromGitHub: true); return
        }
        if let s = InstallScript.bundled(file) { text = s; state = .loaded(fromGitHub: false); return }
        state = .failed("Could not load \(file) from GitHub. Check the Mac's internet connection and try again.")
    }
}

/// Puts the script into the machine over its SSH connection (the terminal's own arguments, so its key and
/// known_hosts are used), where the terminal then runs it in view.
enum InstallScriptUpload {
    @MainActor static func upload(_ script: String, file: String, profile: RemoteProfile) async -> String? {
        await withCheckedContinuation { done in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = SshTerminal.arguments(for: profile) + ["-o", "BatchMode=yes",
                "mkdir -p \(InstallScript.guestDir) && cat > \(InstallScript.guestPath(file)) && chmod 755 \(InstallScript.guestPath(file))"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Paths.toolPath
            proc.environment = env
            let input = Pipe(), err = Pipe()
            proc.standardInput = input; proc.standardOutput = FileHandle.nullDevice; proc.standardError = err
            proc.terminationHandler = { p in
                let why = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                done.resume(returning: p.terminationStatus == 0 ? nil : "Could not copy the script into the machine (ssh status \(p.terminationStatus))\(why.isEmpty ? "." : ": " + why)")
            }
            do {
                try proc.run()
                // the text as edited, with a final newline so the last line runs
                input.fileHandleForWriting.write(Data((script.hasSuffix("\n") ? script : script + "\n").utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                done.resume(returning: "Could not start ssh: \(error.localizedDescription)")
            }
        }
    }
}
