import Foundation
import Darwin

/// One running (or stopped) machine: run.sh as a child process with the profile's environment, its output in a
/// log file, and the guest's serial console (a root shell) on a unix socket. Stop is a clean poweroff typed into
/// that console, because the guest has no power button; Force Quit ends QEMU like pulling the plug.
final class Runner: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case inUseElsewhere          // a QEMU started outside this app has the disk open
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var console = ""
    @Published private(set) var consoleConnected = false
    @Published private(set) var stoppingSince: Date?

    let profileID: UUID
    private var process: Process?
    private var profile: Profile?
    private var serialFD: Int32 = -1
    private var logHandle: FileHandle?
    private let consoleLimit = 80_000

    init(profileID: UUID) { self.profileID = profileID }

    var isActive: Bool { [.starting, .running, .stopping].contains(state) }

    /// Short socket path: unix socket paths are limited to 104 bytes, Application Support paths are long.
    var serialSocket: String { "/tmp/mylinux-\(getuid())-\(profileID.uuidString.prefix(8).lowercased()).serial" }
    var logFile: URL { Paths.logs.appendingPathComponent("\(profileID.uuidString).log") }

    // ---- start ----------------------------------------------------------------------------------------------
    func start(_ p: Profile, settings: AppSettings = .shared) {
        guard !isActive else { return }
        if let problem = p.problems.first { state = .failed(problem); return }
        guard settings.qemuAvailable else { state = .failed(AppSettings.qemuMissingText); return }
        guard let scripts = settings.scriptsDir, FileManager.default.isReadableFile(atPath: scripts.appendingPathComponent("run.sh").path) else {
            state = .failed("run.sh was not found (developer checkout moved, or the app bundle is incomplete)."); return
        }
        guard settings.imagePresent else {
            state = .failed(settings.developerMode ? "No image in \(settings.outDir.path): run ./build.sh or tools/get-image.sh in the checkout."
                                                   : "The myLinux image is not downloaded yet (Download in the sidebar).")
            return
        }
        if Runner.diskInUse(p.appsDisk) { state = .inUseElsewhere; return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: URL(fileURLWithPath: p.appsDisk).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(atPath: p.shareDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: settings.outDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        } catch {
            state = .failed("Could not create folders: \(error.localizedDescription)"); return
        }
        unlink(serialSocket)
        fm.createFile(atPath: logFile.path, contents: nil)
        console = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scripts.appendingPathComponent("run.sh").path]
        proc.currentDirectoryURL = scripts
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.toolPath
        for (k, v) in p.environment(outDir: settings.outDir, serialSocket: serialSocket) { env[k] = v }
        env["PLACER"] = settings.placeWindow ? "1" : "0"
        proc.environment = env
        // straight into the log file, not a pipe: a machine outlives the launcher, and writing to the pipe of a
        // quit launcher would kill run.sh (SIGPIPE) and leave its helper processes behind
        guard let log = try? FileHandle(forWritingTo: logFile) else {
            state = .failed("Could not open the log file \(logFile.path)."); return
        }
        logHandle = log
        proc.standardOutput = log; proc.standardError = log
        proc.standardInput = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] pr in
            DispatchQueue.main.async { self?.finished(status: pr.terminationStatus) }
        }
        do {
            try proc.run()
        } catch {
            state = .failed("Could not start run.sh: \(error.localizedDescription)"); return
        }
        process = proc; profile = p
        state = .starting
        UserDefaults.standard.set(p.id.uuidString, forKey: QuickStart.lastKey)
        connectSerial()
    }

    /// The last lines run.sh wrote, for the message on an unexpected exit.
    private func logTail(lines: Int) -> [String] {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(lines)
    }

    private func finished(status: Int32) {
        closeSerial()
        try? logHandle?.close(); logHandle = nil
        let wasStopping = state == .stopping
        process = nil; stoppingSince = nil
        unlink(serialSocket)
        if wasStopping || status == 0 {
            state = .stopped
        } else {
            let lines = logTail(lines: 4)
            state = .failed(lines.isEmpty ? "myLinux exited with status \(status)." : lines.joined(separator: "\n"))
        }
    }

    // ---- serial console ---------------------------------------------------------------------------------------
    private func connectSerial() {
        let path = serialSocket
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(90)
            var fd: Int32 = -1
            while Date() < deadline {
                guard let self, self.process?.isRunning == true else { return }
                fd = Runner.connectUnix(path)
                if fd >= 0 { break }
                usleep(300_000)
            }
            guard fd >= 0 else {
                DispatchQueue.main.async { if self?.state == .starting { self?.state = .running } }   // running, console unavailable
                return
            }
            self?.readConsole(fd)
        }
    }

    /// Runs on a background queue until the guest side closes (QEMU exited).
    private func readConsole(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.main.async { [weak self] in
            guard let self else { close(fd); return }
            self.serialFD = fd; self.consoleConnected = true
            if self.state == .starting { self.state = .running }
        }
        Runner.readLoop(fd: fd) { [weak self] text in
            DispatchQueue.main.async { self?.appendConsole(text) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.serialFD == fd else { return }
            self.closeSerial()
            // a machine this launcher did not start ends here (there is no child process to report it)
            if self.process == nil && (self.state == .stopping || self.state == .inUseElsewhere) { self.state = .stopped; self.stoppingSince = nil }
        }
    }

    /// The console of a machine started elsewhere (an earlier launcher, a terminal running run.sh with the same
    /// socket): the socket path comes from the profile, so a relaunched launcher can still reach the root shell.
    private var attaching = false
    func attachConsole() {
        guard state == .inUseElsewhere, serialFD < 0, !attaching, FileManager.default.fileExists(atPath: serialSocket) else { return }
        attaching = true
        let path = serialSocket
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = Runner.connectUnix(path)
            DispatchQueue.main.async { self?.attaching = false }
            if fd >= 0 { self?.readConsole(fd) }
        }
    }

    private func appendConsole(_ raw: String) {
        let text = Runner.cleanTerminalText(raw)
        guard !text.isEmpty else { return }
        console += text
        if console.count > consoleLimit { console = String(console.suffix(consoleLimit * 3 / 4)) }
    }

    private func closeSerial() {
        if serialFD >= 0 { close(serialFD); serialFD = -1 }
        consoleConnected = false
    }

    /// Text typed into the guest's root shell.
    func send(_ text: String) {
        guard serialFD >= 0 else { return }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(serialFD, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    // ---- stop --------------------------------------------------------------------------------------------------
    func stop() {
        guard state == .running || state == .starting || (state == .inUseElsewhere && consoleConnected) else { return }
        guard consoleConnected else { forceQuit(); return }
        state = .stopping; stoppingSince = Date()
        send("\u{03}")                       // interrupt whatever the console shell is running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.send("\npoweroff\n") }
    }

    /// Ends QEMU without a guest shutdown (the apps disk is journalled, but recent writes can be lost).
    func forceQuit() {
        if state == .inUseElsewhere, let p = currentOrLastProfileDisk {
            Runner.killDiskUsers(p); state = .stopped; return
        }
        guard let proc = process else { return }
        state = .stopping
        if let disk = profile?.appsDisk { Runner.killDiskUsers(disk) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if proc.isRunning { proc.terminate() } }
    }

    var currentOrLastProfileDisk: String? { profile?.appsDisk ?? ProfileStore.shared.profiles.first { $0.id == profileID }?.appsDisk }

    /// Periodic check for machines started outside the app (Terminal, an earlier launcher session).
    func refreshExternal(disk: String) {
        profile = profile ?? ProfileStore.shared.profiles.first { $0.id == profileID }
        switch state {
        case .stopped, .failed, .inUseElsewhere:
            let inUse = Runner.diskInUse(disk)
            if inUse && state != .inUseElsewhere { state = .inUseElsewhere }
            if !inUse && state == .inUseElsewhere { state = .stopped; closeSerial() }
            if inUse { attachConsole() }
        default: break
        }
    }

    func clearFailure() { if case .failed = state { state = .stopped } }

    // ---- helpers --------------------------------------------------------------------------------------------------
    static func connectUnix(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyMemory(from: $0) } }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { close(fd); return -1 }
        return fd
    }

    static func readLoop(fd: Int32, _ deliver: (String) -> Void) {
        var buf = [UInt8](repeating: 0, count: 8192)
        var pending = [UInt8]()
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            pending += buf[0..<n]
            // hold back an incomplete UTF-8 sequence at the end
            var cut = pending.count
            var i = pending.count - 1, back = 0
            while i >= 0 && back < 4 && (pending[i] & 0xC0) == 0x80 { i -= 1; back += 1 }
            if i >= 0 {
                let lead = pending[i]
                let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
                if need > back + 1 { cut = i }
            }
            deliver(String(decoding: pending[0..<cut], as: UTF8.self))
            pending = Array(pending[cut...])
        }
    }

    /// Serial output without colour codes, cursor movement and carriage returns.
    static func cleanTerminalText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1B}[()][A-Za-z0-9]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        return t.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 && $0.value != 0x7F }
            .map(String.init).joined()
    }

    /// Whether a QEMU process has this disk on its command line.
    static func diskInUse(_ disk: String) -> Bool {
        guard !disk.isEmpty else { return false }
        return run("/usr/bin/pgrep", ["-f", "file=" + NSRegularExpression.escapedPattern(for: disk) + ",if=none"]) == 0
    }

    static func killDiskUsers(_ disk: String) {
        _ = run("/usr/bin/pkill", ["-f", "file=" + NSRegularExpression.escapedPattern(for: disk) + ",if=none"])
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// The runners, one per profile, kept for the life of the app.
final class RunManager: ObservableObject {
    static let shared = RunManager()
    private var runners: [UUID: Runner] = [:]
    private var timer: Timer?

    func runner(for id: UUID) -> Runner {
        if let r = runners[id] { return r }
        let r = Runner(profileID: id)
        runners[id] = r
        return r
    }

    var active: [Runner] { runners.values.filter(\.isActive) }

    func startWatching(_ store: ProfileStore) {
        timer?.invalidate()
        let tick = { [weak self, weak store] in
            guard let self, let store else { return }
            for p in store.profiles {
                let r = self.runner(for: p.id)
                DispatchQueue.global(qos: .utility).async {
                    let disk = p.appsDisk
                    DispatchQueue.main.async { r.refreshExternal(disk: disk) }
                }
            }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in tick() }
    }
}
