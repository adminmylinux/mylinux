import Foundation

/// How the launcher's wizards (Claude Install…, Codex Install…) reach a Windows machine. Windows reads no Mac folder,
/// so there is no share to leave a question in, as there is for Omarchy. What there is: the virtio port
/// dev.mylinux.host between the launcher's helper beside the machine (`--windows-display`, WindowsDisplay.swift) and
/// the agent inside (windows/mylinux-agent.ps1). The wizards keep their way of working with files: a folder on the
/// Mac, <machine folder>/link, laid out as a share is (.mylinux/<tool>/ and mylinux-tools/control/), and the helper
/// carries what is put there to Windows and what Windows says back:
///
///   wizard                         helper                                  agent in Windows
///   control/claude-<id>.cmd   →    "ask <id> <script> <arguments> <input>" →  runs the script as the signed-in user
///   .mylinux/claude/request-…      (the request is taken with the command)
///   status-, progress-, result- ←  "say <id> <a line of the script>"       ←  what the script prints
///                                  "end <id> <exit code>"
///
/// The script is windows/claude_codex_setup.ps1, sent with every question: the wizard and the script are one version.
/// A request (a token, or Codex's login) is in the link folder, which is the Mac user's alone, only until the helper
/// has taken it, which it does when the agent has been heard from in the last seconds; it never reaches a disk the
/// machine shares. Nobody taking a command (the machine was started by a launcher from before this, or nobody is
/// signed in to Windows) is what the wizards tell as "not running".
enum WindowsLink {
    static let scriptName = "claude_codex_setup.ps1"
    static let tools: Set<String> = ["claude", "codex"]
    static let whats: Set<String> = ["status", "apply"]

    static func folder(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("link", isDirectory: true) }

    /// The script built into the app (Contents/Resources/runtime/windows), or the checkout's when run from a build.
    static func bundledScript() -> String? {
        let dirs = [Paths.bundledRuntime?.appendingPathComponent("windows"),
                    Paths.buildRepo.map { URL(fileURLWithPath: $0).appendingPathComponent("windows") }]
        for case let dir? in dirs {
            if let s = try? String(contentsOf: dir.appendingPathComponent(scriptName), encoding: .utf8), s.contains("function Claude-Apply") { return s }
        }
        return nil
    }

    /// Why a wizard cannot reach this Windows machine yet (nil when it can, and for every other kind of machine).
    static func notYet(_ machine: Profile) -> String? {
        guard machine.kind == .windows, !machine.windowsInstalled else { return nil }
        return "Windows is still being installed in this machine. When it is, and the machine has been started again (Machine › Restart), the wizard can look inside."
    }

    static func isID(_ s: String) -> Bool { s.range(of: "^[0-9a-f]{8,32}$", options: .regularExpression) != nil }

    /// What a command file asks: "claude status <id>".
    struct Question: Equatable { var tool: String, what: String, id: String }
    static func question(_ text: String) -> Question? {
        let w = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard w.count == 3, tools.contains(w[0]), whats.contains(w[1]), isID(w[2]) else { return nil }
        return Question(tool: w[0], what: w[1], id: w[2])
    }

    /// The line for the port: the script, the arguments (one a line) and the input, each in base64 ("-" for no input).
    static func askLine(_ q: Question, script: String, input: Data?) -> String {
        let b64 = { (d: Data) in d.base64EncodedString() }
        return "ask \(q.id) \(b64(Data(script.utf8))) \(b64(Data("\(q.tool)\n\(q.what)".utf8))) \(input.map { $0.isEmpty ? "-" : b64($0) } ?? "-")"
    }

    /// What Windows says: a line of the script ("say <id> <base64>": a JSON object with "kind" and "data"), or its end.
    enum Answer: Equatable { case said(id: String, kind: String, data: Data), ended(id: String, code: Int) }
    static func answer(_ line: String) -> Answer? {
        let w = line.split(separator: " ").map(String.init)
        guard w.count == 3, isID(w[1]) else { return nil }
        if w[0] == "end", let code = Int(w[2]) { return .ended(id: w[1], code: code) }
        guard w[0] == "say", let raw = Data(base64Encoded: w[2]),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let kind = obj["kind"] as? String,
              ["status", "step", "result"].contains(kind), let data = obj["data"] as? [String: Any],
              let out = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return nil }
        return .said(id: w[1], kind: kind, data: out)
    }

    /// A tool's files in a link folder (or a share): the names Claude Install has had since it was Omarchy's alone.
    struct Files {
        let base: String, tool: String
        var folder: URL { URL(fileURLWithPath: base).appendingPathComponent(".mylinux/\(tool)", isDirectory: true) }
        var control: URL { URL(fileURLWithPath: base).appendingPathComponent("mylinux-tools/control", isDirectory: true) }
        var scriptFile: URL { folder.appendingPathComponent(WindowsLink.scriptName) }
        func commandFile(_ id: String) -> URL { control.appendingPathComponent("\(tool)-\(id).cmd") }
        func statusFile(_ id: String) -> URL { folder.appendingPathComponent("status-\(id).json") }
        func requestFile(_ id: String) -> URL { folder.appendingPathComponent("request-\(id).json") }
        func progressFile(_ id: String) -> URL { folder.appendingPathComponent("progress-\(id).jsonl") }
        func resultFile(_ id: String) -> URL { folder.appendingPathComponent("result-\(id).json") }

        /// The folders, for the Mac user alone, and the script in place: nil, or what went wrong.
        func prepare(script text: String? = WindowsLink.bundledScript()) -> String? {
            guard let text else { return "The launcher has no copy of the setup script for Windows." }
            do {
                let mine: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: base), withIntermediateDirectories: true, attributes: mine)
                try FileManager.default.setAttributes(mine, ofItemAtPath: base)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: mine)
                try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true, attributes: mine)
                try text.write(to: scriptFile, atomically: true, encoding: .utf8)
            } catch { return "Could not write into \(folder.path): \(error.localizedDescription)" }
            sweep()
            return nil
        }

        func ask(_ what: String, _ id: String) -> Bool {
            (try? "\(tool) \(what) \(id)\n".write(to: commandFile(id), atomically: true, encoding: .utf8)) != nil
        }

        /// The request, for its owner only, there whole or not at all.
        func writeRequest(_ object: [String: Any], id: String) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
            let tmp = folder.appendingPathComponent(".request-\(id).tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
            do { try FileManager.default.moveItem(at: tmp, to: requestFile(id)); return true }
            catch { try? FileManager.default.removeItem(at: tmp); return false }
        }

        /// A request nobody took after a minute, and what earlier runs left after an hour: out of the folder.
        func sweep(now: Date = Date()) {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let name = url.lastPathComponent
                guard name != WindowsLink.scriptName, let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                let age = now.timeIntervalSince(written)
                let request = name.hasPrefix("request-") || name.hasPrefix(".request-")
                if request ? age > ClaudeInstall.requestLifetime : age > 3600 { try? fm.removeItem(at: url) }
            }
        }

        func forget(_ id: String) {
            for url in [commandFile(id), statusFile(id), requestFile(id), progressFile(id), resultFile(id)] { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The helper's part: commands out of the link folder to Windows, and Windows's answers into it. One for the
    /// helper's two threads (the one that reads the port, and the one that writes it every second).
    final class Bridge {
        let link: String
        private let lock = NSLock()
        private var pending: [String: Question] = [:]         // asked, and not yet at its end
        private var answered: Set<String> = []                // an apply whose result has come
        private var heardAt = Date.distantPast

        init(link: String) { self.link = link }

        /// Windows's agent said "can=ask" (it does with every answer): it is there, and takes questions. The agent of a
        /// launcher before 0.7.72 answers too, with its memory figure alone, and would let a question fall.
        func heard(now: Date = Date()) { lock.lock(); heardAt = now; lock.unlock() }
        func alive(now: Date = Date()) -> Bool { lock.lock(); defer { lock.unlock() }; return now.timeIntervalSince(heardAt) < 10 }

        /// The lines to send now: every command in the link folder, taken (removed, with its request). Nothing while
        /// the agent is not heard from: a question nobody would answer stays where the wizard sees it was not taken.
        func outgoing(now: Date = Date()) -> [String] {
            guard alive(now: now) else { return [] }
            let fm = FileManager.default
            let control = URL(fileURLWithPath: link).appendingPathComponent("mylinux-tools/control", isDirectory: true)
            var lines: [String] = []
            for url in ((try? fm.contentsOfDirectory(at: control, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) where url.pathExtension == "cmd" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                try? fm.removeItem(at: url)
                guard let q = WindowsLink.question(text), url.lastPathComponent == "\(q.tool)-\(q.id).cmd" else { continue }
                let files = Files(base: link, tool: q.tool)
                guard let script = try? String(contentsOf: files.scriptFile, encoding: .utf8) else { continue }
                var input: Data?
                if q.what == "apply" {
                    input = try? Data(contentsOf: files.requestFile(q.id))
                    try? fm.removeItem(at: files.requestFile(q.id))            // taken: it is on its way, and nowhere else
                    guard input != nil else { continue }
                    try? Data().write(to: files.progressFile(q.id))
                }
                lock.lock(); pending[q.id] = q; lock.unlock()
                lines.append(WindowsLink.askLine(q, script: script, input: input))
            }
            return lines
        }

        /// A line from Windows: into the file the wizard reads. Only for a question this helper asked.
        func incoming(_ line: String) {
            guard let a = WindowsLink.answer(line) else { return }
            lock.lock()
            let q: Question?
            switch a {
            case .said(let id, let kind, _): q = pending[id]; if kind == "result", q != nil { answered.insert(id) }
            case .ended(let id, _): q = pending.removeValue(forKey: id)
            }
            let hadResult: Bool = { if case .ended(let id, _) = a { return answered.remove(id) != nil }; return false }()
            lock.unlock()
            guard let q else { return }
            let files = Files(base: link, tool: q.tool)
            switch a {
            case .said(let id, let kind, let data):
                switch (kind, q.what) {
                case ("status", "status"): try? data.write(to: files.statusFile(id), options: .atomic)
                case ("step", "apply"):
                    if let h = try? FileHandle(forWritingTo: files.progressFile(id)) { h.seekToEndOfFile(); h.write(data + Data([0x0A])); try? h.close() }
                case ("result", "apply"): try? data.write(to: files.resultFile(id), options: .atomic)
                default: break
                }
            case .ended(let id, let code):
                // a setup that ended without saying how: told, so the wizard does not wait for it
                guard q.what == "apply", !hadResult else { return }
                var steps = ((try? String(contentsOf: files.progressFile(id), encoding: .utf8)) ?? "").split(separator: "\n")
                    .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                steps.append(["step": "setup", "title": "The setup", "state": "failed",
                              "detail": "The script inside Windows ended (\(code)) without an outcome. Its log is %LOCALAPPDATA%\\myLinux\\agent.log there."])
                let failed: [String: Any] = ["ok": false, "steps": steps]
                if let data = try? JSONSerialization.data(withJSONObject: failed) { try? data.write(to: files.resultFile(id), options: .atomic) }
            }
        }
    }
}
