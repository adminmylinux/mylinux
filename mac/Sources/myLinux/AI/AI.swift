import Foundation

/// AI that answers in JSON, through the person's own Claude Code or Codex on this Mac (Settings › AI), as My Recorder
/// does (prjs/myrecorder, AI.swift). Each runs from an empty folder with its tools, settings and saved sessions off, so
/// it only reads the prompt and answers; the launcher never sees the sign-in. Ask AI… (AskAI.swift) is what uses it.
enum AI {
    enum Provider: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var label: String { self == .claude ? "Claude Code" : "Codex" }
    }
    static var provider: Provider { Provider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .claude }
    static var claudeModel: String { UserDefaults.standard.string(forKey: "ai.claudeModel").flatMap { $0.isEmpty ? nil : $0 } ?? "sonnet" }
    static var codexModel: String { UserDefaults.standard.string(forKey: "ai.codexModel") ?? "" }     // empty: Codex's own default

    struct Failure: LocalizedError { let errorDescription: String?; init(_ s: String) { errorDescription = s } }

    /// The answer's JSON object (models sometimes wrap it in prose or ``` fences).
    static func json<T: Decodable>(_ type: T.Type, system: String, user: String, via provider: Provider = provider) async throws -> T {
        let content = provider == .claude ? try await ClaudeCode.ask(system: system, user: user, model: claudeModel)
                                          : try await Codex.ask(system: system, user: user, model: codexModel)
        return try decode(type, from: content)
    }
    static func decode<T: Decodable>(_ type: T.Type, from content: String) throws -> T {
        guard let a = content.firstIndex(of: "{"), let b = content.lastIndex(of: "}"), a < b else { throw Failure("the AI gave no JSON: \(content.prefix(200))") }
        do { return try JSONDecoder().decode(T.self, from: Data(content[a...b].utf8)) }
        catch { throw Failure("the AI's answer could not be read: \(content.prefix(200))") }
    }

    /// Whether `provider` can answer now, with a line saying so for Settings and Ask AI.
    static func check(_ provider: Provider) async -> (ok: Bool, text: String) {
        switch provider {
        case .claude:
            guard let s = await ClaudeCode.status() else { return (false, "Claude Code isn't installed on this Mac. Install it, then run claude once in Terminal to sign in.") }
            guard s.loggedIn else { return (false, "Claude Code isn't signed in. Run claude in Terminal and sign in.") }
            guard s.authMethod == "claude.ai" else { return (true, "Claude Code is signed in with \(s.authMethod ?? "an API key")") }
            return (true, "Signed in with your Claude\(s.subscriptionType.map { " " + $0.capitalized } ?? "") plan")
        case .codex:
            guard let s = await Codex.status() else { return (false, "Codex isn't installed on this Mac. Install it, then run codex once in Terminal to sign in.") }
            guard s.hasPrefix("Logged in") else { return (false, "Codex isn't signed in. Run codex in Terminal and sign in.") }
            return (true, s.contains("ChatGPT") ? "Signed in with your ChatGPT plan" : "Codex is signed in with an API key")
        }
    }
}

/// The person's own Claude Code: `claude -p` with no tools, settings, MCP servers, slash commands or saved session.
enum ClaudeCode {
    /// Apps opened from Finder don't get the shell's PATH, so look where the installers put it.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    struct Status: Decodable { let loggedIn: Bool; let authMethod: String?; let subscriptionType: String? }
    /// nil: not installed.
    static func status() async -> Status? {
        guard let exe = executable, let out = try? await AICLI.run(exe, ["auth", "status"]) else { return nil }
        return (try? JSONDecoder().decode(Status.self, from: out)) ?? Status(loggedIn: false, authMethod: nil, subscriptionType: nil)
    }
    static func ask(system: String, user: String, model: String) async throws -> String {
        guard let exe = executable else { throw AI.Failure("Claude Code isn't installed on this Mac: install it and sign in, or choose Codex in Settings › AI.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await AICLI.run(exe, ["-p", "--output-format", "json", "--model", model, "--system-prompt", system,
                                           "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
                                           "--no-session-persistence"], input: user, in: dir)
        struct Result: Decodable { let is_error: Bool?; let result: String? }
        guard let r = try? JSONDecoder().decode(Result.self, from: out), let text = r.result, r.is_error != true else {
            let why = (try? JSONDecoder().decode(Result.self, from: out))?.result ?? String(decoding: out.prefix(300), as: UTF8.self)
            throw AI.Failure("Claude Code: \(why.isEmpty ? "no answer" : why)")
        }
        return text
    }
}

/// The person's own Codex: `codex exec` from an empty folder in a read-only sandbox, without their config, rules or
/// saved sessions.
enum Codex {
    /// Where the installers put it, newest nvm Node first (apps opened from Finder don't get the shell's PATH).
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path, nvm = "\(home)/.nvm/versions/node"
        let nodes = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return (["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] + nodes.map { "\(nvm)/\($0)/bin/codex" })
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    /// `codex login status`, e.g. "Logged in using ChatGPT"; nil: not installed.
    static func status() async -> String? {
        guard let exe = executable, let out = try? await AICLI.run(exe, ["login", "status"], errorsToo: true) else { return nil }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func ask(system: String, user: String, model: String) async throws -> String {
        guard let exe = executable else { throw AI.Failure("Codex isn't installed on this Mac: install it (npm install -g @openai/codex) and sign in, or choose Claude Code in Settings › AI.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mylinux-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // stdout is only the final answer; the log goes to stderr. codex exec has no system prompt flag, so it leads the prompt.
        let out = try await AICLI.run(exe, ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                                           "--sandbox", "read-only", "--color", "never", "-C", dir.path] + (model.isEmpty ? [] : ["-m", model]) + ["-"],
                                      input: system + "\n\n" + user, in: dir)
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AI.Failure("Codex gave no answer. Run codex in Terminal to check that it's signed in.") }
        return text
    }
}

/// Runs a command-line AI with the prompt on stdin and returns its stdout; stopped after 3 minutes so a stuck run can't hang.
enum AICLI {
    static func run(_ exe: URL, _ args: [String], input: String = "", in dir: URL? = nil, errorsToo: Bool = false) async throws -> Data {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment.filter { $0.key != "CLAUDECODE" }      // when started from inside Claude Code
        // an npm-installed CLI is a node script (#!/usr/bin/env node), and the node next to it isn't on a Finder app's PATH
        env["PATH"] = exe.deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = errorsToo ? stdout : FileHandle.nullDevice
        try p.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if p.isRunning { p.terminate() } }
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {        // write and read off the main thread: a long prompt fills the pipe
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                done.resume(returning: data)
            }
        }
    }
}
