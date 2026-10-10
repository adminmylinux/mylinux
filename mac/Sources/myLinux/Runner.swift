import Foundation
import Darwin
import Combine

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
    /// A server's sshd has answered a login since this start, so a terminal opened now connects.
    @Published private(set) var sshReady = false
    /// Waiting for that login (after Start, or a Terminal press before it), to open the terminal then.
    @Published private(set) var waitingForSSH = false
    /// Whether the terminal opens when that login has answered (not for a start from the command line).
    private var wantsTerminal = true
    // ---- the clock: every step is timed and shown in seconds ("Starting… 7 s", "Ready in 14 s") ----------------
    /// When this start began, when a server's sshd first answered, when it was ready (cloud folders mounted).
    @Published private(set) var startedAt: Date?
    @Published private(set) var sshAnsweredAt: Date?
    @Published private(set) var readyAt: Date?
    /// Mounting the cloud folders inside, between the answer and ready.
    @Published private(set) var mountingCloud = false
    /// A restart (Install Script… › Cloud): when it began, and when the machine was down.
    @Published private(set) var restartBeganAt: Date?
    @Published private(set) var stoppedAt: Date?
    /// Seconds from Start to ready, once there.
    var readyIn: TimeInterval? { readyAt.flatMap { r in startedAt.map { r.timeIntervalSince($0) } } }
    /// "7 s": the way every duration in the launcher reads.
    static func seconds(_ t: TimeInterval) -> String { t < 0.5 ? "<1 s" : "\(Int(t.rounded())) s" }

    let profileID: UUID
    private var process: Process?
    /// QEMU's process while this launcher runs the machine (its window is that app's)
    var qemuPID: pid_t? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    private var profile: Profile?
    private var serialFD: Int32 = -1
    private var logHandle: FileHandle?
    private let consoleLimit = 80_000

    init(profileID: UUID) { self.profileID = profileID }

    var isActive: Bool { [.starting, .running, .stopping].contains(state) }
    /// macOS's microphone question was put for this machine in this run of the launcher: not twice, whatever came of it.
    private var askedMicrophone = false

    /// Short socket path: unix socket paths are limited to 104 bytes, Application Support paths are long.
    var serialSocket: String { "/tmp/mylinux-\(getuid())-\(profileID.uuidString.prefix(8).lowercased()).serial" }
    /// QEMU's control socket for an Omarchy machine: its console is a login prompt, not a root shell, so Stop is a
    /// press of the virtual power button there instead of "poweroff" typed into the console.
    var qmpSocket: String { "/tmp/mylinux-\(getuid())-\(profileID.uuidString.prefix(8).lowercased()).qmp" }
    var logFile: URL { Paths.logs.appendingPathComponent("\(profileID.uuidString).log") }

    // ---- start ----------------------------------------------------------------------------------------------
    /// `showTerminal`: a server's terminal opens by itself once its sshd answers (false for a start asked from the
    /// command line: an agent's test machine does not put a window in front of what the user is doing).
    func start(_ p: Profile, settings: AppSettings = .shared, showTerminal: Bool = true) {
        guard !isActive else { return }
        if let problem = p.problems.first { state = .failed(problem); return }
        // "every key to the machine": QEMU's event tap needs Accessibility, which macOS credits to this app and
        // checks once, when the machine starts. Ask first, and start after it is granted.
        if !p.isServer, p.grab == "full", !KeyboardGrab.permitted {
            KeyboardGrab.askPermission()
            state = .failed("Sending every key to the machine needs Accessibility permission for myLinux Launcher. Turn it on in System Settings › Privacy & Security › Accessibility, then press Start again.")
            return
        }
        guard settings.qemuAvailable else { state = .failed(AppSettings.qemuMissingText); return }
        guard let scripts = settings.scriptsDir, FileManager.default.isReadableFile(atPath: scripts.appendingPathComponent(p.script).path) else {
            state = .failed("\(p.script) was not found (developer checkout moved, or the app bundle is incomplete)."); return
        }
        if p.isServer {
            // an existing machine has its disk and seed; only a new one needs the downloaded image and firmware
            let created = FileManager.default.fileExists(atPath: p.appsDisk) && FileManager.default.fileExists(atPath: p.machineFolder.appendingPathComponent(p.kind.firstStartFile).path)
            let downloaded = settings.serverImagePresent(p.kind)
            guard created || downloaded else { state = .failed("\(p.kind.title) is not downloaded yet (Download on this page)."); return }
            if p.kind == .tiny {
                guard settings.runtimeHasMke2fs else { state = .failed("Tiny Alpine needs the accelerated QEMU, 11.1.1-17 or later (Settings › QEMU)."); return }
            } else {
                guard downloaded || FileManager.default.fileExists(atPath: settings.outDir.appendingPathComponent("\(p.kind.rawValue)/edk2-aarch64-code.fd").path) else {
                    state = .failed("The UEFI firmware is missing (Download \(p.kind.title) on this page)."); return
                }
            }
        } else if p.kind.runsDesktop {
            guard settings.runtimePresent else { state = .failed("\(p.kind.title) needs the accelerated QEMU (Settings › QEMU › Download)."); return }
            // an existing machine has its own disk and boot files; only a new one needs the downloaded guest. Windows
            // needs Microsoft's ISO until it is installed, and the firmware always
            if p.kind == .windows {
                guard p.windowsInstalled ? FileManager.default.fileExists(atPath: settings.outDir.appendingPathComponent("windows/edk2-aarch64-code.fd").path)
                                         : settings.desktopPresent(.windows) else {
                    state = .failed(p.windowsInstalled ? "Windows's firmware is missing (Get Windows… on this page fetches it)."
                                                       : "Windows is not there to install yet (Get Windows… on this page)."); return
                }
            } else {
                guard p.desktopCreated || settings.desktopPresent(p.kind) else { state = .failed("\(p.kind.title) is not downloaded yet (Download on this page)."); return }
            }
        } else {
            guard settings.imagePresent else {
                state = .failed(settings.developerMode ? "No image in \(settings.outDir.path): run ./build.sh or tools/get-image.sh in the checkout."
                                                       : "The myLinux image is not downloaded yet (Download in the sidebar).")
                return
            }
        }
        if Runner.diskInUse(p.appsDisk) { state = .inUseElsewhere; return }
        // The sound device has a microphone, and QEMU is this app's child: macOS asks once whether myLinux Launcher may
        // use the Mac's. The machine starts after the answer, so QEMU opens its input knowing it (a no leaves the
        // machine with sound out and a silent microphone).
        if p.kind.runsDesktop, p.sound, !askedMicrophone, Microphone.shouldAsk {
            askedMicrophone = true
            Microphone.ask { [weak self] in self?.start(p, settings: settings, showTerminal: showTerminal) }
            return
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: URL(fileURLWithPath: p.appsDisk).deletingLastPathComponent(), withIntermediateDirectories: true)
            if !p.shareDir.isEmpty { try fm.createDirectory(atPath: p.shareDir, withIntermediateDirectories: true) }
            try fm.createDirectory(at: settings.outDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        } catch {
            state = .failed("Could not create folders: \(error.localizedDescription)"); return
        }
        // a Windows machine made to install by itself: its answers become the answer file now, in the ISO's language
        if let problem = WindowsUnattended.prepare(p, isoLabel: settings.windowsISO) { state = .failed(problem); return }
        unlink(serialSocket); unlink(qmpSocket)
        fm.createFile(atPath: logFile.path, contents: nil)
        console = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scripts.appendingPathComponent(p.script).path]
        proc.currentDirectoryURL = scripts
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.toolPath
        for (k, v) in p.environment(outDir: settings.outDir, serialSocket: serialSocket, qmpSocket: qmpSocket) { env[k] = v }
        // the launcher's own binary does the Omarchy clipboard bridge (--omarchy-clipboard), no python3 needed
        if let helper = Bundle.main.executablePath { env["MYLINUX_HELPER"] = helper }
        env["PLACER"] = settings.placeWindow ? "1" : "0"
        // the machine's Machine › Restart (QEMU runtime patch) asks this launcher through MachineLink
        env["MYLINUX_LINK_SCOPE"] = Paths.support.path
        if let id = Bundle.main.bundleIdentifier { env["MYLINUX_LAUNCHER_ID"] = id }
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
            state = .failed("Could not start \(p.script): \(error.localizedDescription)"); return
        }
        process = proc; profile = p
        state = .starting
        startedAt = Date(); sshAnsweredAt = nil; readyAt = nil; mountingCloud = false
        UserDefaults.standard.set(p.id.uuidString, forKey: QuickStart.lastKey)
        if p.kind == .windows { awaitControlSocket() } else { connectSerial() }
        sshReady = false
        // myLinux: its cloud folders are mounted through the root console once its shell is up (appendConsole)
        cloudConsolePending = p.kind == .mylinux ? (p.cloudFolders, p.macFolders) : nil
        if p.isServer { wantsTerminal = showTerminal; openTerminal(p, show: showTerminal) }
    }
    /// myLinux's cloud folders, to mount at the console's first prompt after a start (CloudFolder.consoleScript;
    /// also with none ticked, so links to folders taken away go).
    private var cloudConsolePending: ([String], [MacFolder])?

    /// The last lines run.sh wrote, for the message on an unexpected exit.
    private func logTail(lines: Int) -> [String] {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(lines)
    }

    private func finished(status: Int32) {
        closeSerial()
        sshReady = false
        if let p = restartWith {
            restartWith = nil; stoppedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start(p) }
        }
        try? logHandle?.close(); logHandle = nil
        let wasStopping = state == .stopping
        process = nil; stoppingSince = nil
        unlink(serialSocket); unlink(qmpSocket)
        if wasStopping || status == 0 {
            state = .stopped
        } else {
            let lines = logTail(lines: 4)
            state = .failed(lines.isEmpty ? "myLinux exited with status \(status)." : lines.joined(separator: "\n"))
        }
    }

    /// A Windows machine has no console to wait for: it is running when QEMU has made its control socket (its window
    /// is up then), which run-windows.sh's own preparations (the tools disc, the machine's app) come before.
    private func awaitControlSocket() {
        let path = qmpSocket
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, !FileManager.default.fileExists(atPath: path) {
                guard let self, self.process?.isRunning == true else { return }
                usleep(300_000)
            }
            DispatchQueue.main.async { if self?.state == .starting { self?.state = .running } }
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
            if self.process == nil && (self.state == .stopping || self.state == .inUseElsewhere) { self.endedElsewhere() }
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
        if let picked = cloudConsolePending, process != nil, console.range(of: #"(^|\n)[^\n]*# ?$"#, options: .regularExpression) != nil {
            cloudConsolePending = nil
            send(CloudFolder.consoleScript(picked.0, mac: picked.1) + "\n")
        }
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

    /// A server is a terminal: its window opens once its sshd answers, on its own after a start and from the Terminal
    /// button. Before that, QEMU's forwarded port accepts the connection with nothing behind it and a terminal would
    /// fail with "timed out during banner exchange" (a first Alpine start takes about 28 s), so a real ssh login is
    /// the test, and a press during the wait just waits along.
    /// `show` false only waits for the login (so `sshReady` and the clock are right) and opens nothing; a Terminal press
    /// during that wait still gets its window.
    func openTerminal(_ p: Profile, show: Bool = true) {
        let profile = p.terminalProfile
        if show { wantsTerminal = true }
        if sshReady { if show { Runner.showTerminal(p) }; return }
        guard !waitingForSSH else { return }
        waitingForSSH = true
        let args = SshTerminal.arguments(for: profile) + ["true"]
        let startedAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { DispatchQueue.main.async { self?.waitingForSSH = false } }
            while Date().timeIntervalSince(startedAt) < 240 {
                guard let self, self.isActive || self.state == .inUseElsewhere, self.profileID == p.id else { return }
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                t.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3"] + args
                var env = ProcessInfo.processInfo.environment; env["PATH"] = Paths.toolPath; t.environment = env
                t.standardInput = FileHandle.nullDevice; t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
                if (try? t.run()) != nil {
                    t.waitUntilExit()
                    if t.terminationStatus == 0 {
                        // the cloud folders (Install Script… › Cloud): mounted before the terminal opens, so ~/Dropbox is there
                        DispatchQueue.main.sync { self.sshAnsweredAt = Date(); self.mountingCloud = !p.cloudFolders.isEmpty || !p.macFolders.isEmpty }
                        self.mountCloudFolders(p, sshArgs: SshTerminal.arguments(for: profile))
                        DispatchQueue.main.async {
                            self.mountingCloud = false; self.readyAt = Date()
                            self.sshReady = true; self.waitingForSSH = false
                            if self.wantsTerminal { Runner.showTerminal(p) }
                        }
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 1)      // each try already waits up to 3 s for the banner
            }
        }
    }

    /// The terminal in the machine's own app (MachineApp), or in the launcher when there is none.
    static func showTerminal(_ p: Profile) {
        if !MachineApp.show(p) { RemoteWindowController.show(p.terminalProfile) }
    }

    /// Mounts the ticked cloud folders inside and takes out the others (CloudFolder.mountScript), over ssh; waits for
    /// it, up to 20 s. Nothing to do on a machine that never had any.
    private func mountCloudFolders(_ p: Profile, sshArgs: [String]) {
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        t.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] + sshArgs + ["sh", "-s"]
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Paths.toolPath; t.environment = env
        let input = Pipe(); t.standardInput = input
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return }
        input.fileHandleForWriting.write(Data(CloudFolder.mountScript(p.cloudFolders, mac: p.macFolders).utf8))
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while t.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if t.isRunning { t.terminate() }
    }

    /// Shut down, then start again with `p` (new cloud folders are attached only when QEMU starts).
    func restart(_ p: Profile) {
        restartBeganAt = Date(); stoppedAt = nil
        if state == .inUseElsewhere {
            // started by an earlier launcher: shut down through its control socket, started here once it is gone
            restartWith = p; stop()
            if state != .stopping { restartWith = nil; state = .failed("\(p.name) could not be shut down for the restart.") }
            return
        }
        guard isActive else { stoppedAt = restartBeganAt; start(p); return }
        restartWith = p
        stop()
    }
    private var restartWith: Profile?

    // ---- stop --------------------------------------------------------------------------------------------------
    func stop() {
        // a server started by an earlier launcher is still reachable: its QMP socket is named after the machine
        guard state == .running || state == .starting || canStopElsewhere else { return }
        if profile?.kind.runsDesktop == true || profile?.isServer == true {
            state = .stopping; stoppingSince = Date()
            let path = qmpSocket, tiny = profile?.kind == .tiny
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Tiny Alpine's kernel has no power button: the power key of its keyboard instead (BusyBox acpid acts on it)
                let ok = tiny ? Runner.qmp(path, json: #"{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"power"}]}}"#)
                              : Runner.qmp(path, execute: "system_powerdown")
                if !ok { DispatchQueue.main.async { self?.forceQuit() } }
            }
            return
        }
        guard consoleConnected else { forceQuit(); return }
        state = .stopping; stoppingSince = Date()
        send("\u{03}")                       // interrupt whatever the console shell is running
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.send("\npoweroff\n") }
    }

    /// A machine started by an earlier launcher (updated or restarted since) can still be shut down from here: over
    /// its console, or a server's or Omarchy's QMP socket (named after the machine).
    var canStopElsewhere: Bool {
        guard state == .inUseElsewhere else { return false }
        let qmp = profile?.isServer == true || profile?.kind.runsDesktop == true
        return consoleConnected || (qmp && FileManager.default.fileExists(atPath: qmpSocket))
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
    func refreshExternal(inUse: Bool) {
        profile = profile ?? ProfileStore.shared.profiles.first { $0.id == profileID }
        switch state {
        case .stopping where process == nil:
            // shut down from here while another launcher had started it: done once its QEMU is gone
            if !inUse { closeSerial(); endedElsewhere() }
        case .stopped, .failed, .inUseElsewhere:
            if inUse && state != .inUseElsewhere { state = .inUseElsewhere }
            if !inUse && state == .inUseElsewhere { state = .stopped; closeSerial() }
            if inUse { attachConsole() }
        default: break
        }
    }

    /// A machine this launcher did not start is gone: stopped, and started here again when that was a restart.
    private func endedElsewhere() {
        state = .stopped; stoppingSince = nil
        if let p = restartWith {
            restartWith = nil; stoppedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start(p) }
        }
    }

    func clearFailure() { if case .failed = state { state = .stopped } }

    // ---- a server's own app (MachineApp): the state the launcher reports, and the copy the app keeps ------------
    /// What the machine's app shows: the state and the clock (a machine run by an earlier launcher counts as running).
    var report: [String: Any] {
        var d: [String: Any] = ["id": profileID.uuidString, "mountingCloud": mountingCloud, "sshReady": sshReady]
        switch state {
        case .stopped: d["state"] = "stopped"
        case .starting: d["state"] = "starting"
        case .running, .inUseElsewhere: d["state"] = "running"
        case .stopping: d["state"] = "stopping"
        case .failed(let why): d["state"] = "failed"; d["why"] = why
        }
        for (k, v) in [("startedAt", startedAt), ("sshAnsweredAt", sshAnsweredAt), ("readyAt", readyAt),
                       ("restartBeganAt", restartBeganAt), ("stoppedAt", stoppedAt)] {
            if let v { d[k] = v.timeIntervalSince1970 }
        }
        return d
    }

    /// In the machine's app: the launcher's runner, as reported.
    func mirror(_ d: [AnyHashable: Any]) {
        switch d["state"] as? String {
        case "starting": state = .starting
        case "running": state = .running
        case "stopping": state = .stopping
        case "failed": state = .failed(d["why"] as? String ?? "The machine stopped.")
        default: state = .stopped
        }
        func date(_ k: String) -> Date? { (d[k] as? Double).map(Date.init(timeIntervalSince1970:)) }
        startedAt = date("startedAt"); sshAnsweredAt = date("sshAnsweredAt"); readyAt = date("readyAt")
        stoppedAt = date("stoppedAt")
        // a restart asked for here counts from the ask until the launcher's own begins
        if let began = date("restartBeganAt") ?? restartBeganAt { restartBeganAt = max(began, restartBeganAt ?? began) }
        mountingCloud = d["mountingCloud"] as? Bool ?? false
        sshReady = d["sshReady"] as? Bool ?? false
    }

    /// In the machine's app, when it asks the launcher for a restart: the clock starts now.
    func mirrorRestartAsked() { restartBeganAt = Date(); stoppedAt = nil; readyAt = nil; sshAnsweredAt = nil }

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

    /// One QMP command on QEMU's control socket: read the greeting, negotiate, send, and wait for the reply.
    static func qmp(_ path: String, execute command: String) -> Bool { qmp(path, json: "{\"execute\":\"\(command)\"}") }
    /// One QMP command given as its JSON (one with arguments).
    static func qmp(_ path: String, json: String) -> Bool {
        let fd = connectUnix(path)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        func readLine() -> String? {
            var line = [UInt8](); var b: UInt8 = 0
            while Darwin.read(fd, &b, 1) == 1 { if b == 0x0A { return String(decoding: line, as: UTF8.self) }; line.append(b) }
            return nil
        }
        func send(_ text: String) -> Bool { text.withCString { Darwin.write(fd, $0, strlen($0)) } > 0 }
        /// the reply to a command, skipping the events QEMU interleaves
        func reply() -> Bool {
            for _ in 0..<20 { guard let l = readLine() else { return false }; if l.contains("\"return\"") { return true }; if l.contains("\"error\"") { return false } }
            return false
        }
        guard readLine() != nil, send("{\"execute\":\"qmp_capabilities\"}\n"), reply() else { return false }
        return send(json + "\n") && reply()
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

    /// The command-line pattern of a QEMU that has this disk open. Both scripts pass the disk as a -drive option
    /// ("file=<disk>,..."); run.sh puts file= first, run-omarchy.sh after if=none,id=root, so only the option's
    /// own text is matched, not its neighbours.
    static func diskPattern(_ disk: String) -> String {
        "(^|[ ,])file=" + NSRegularExpression.escapedPattern(for: disk) + "(,|$)"
    }

    /// Whether a QEMU process has this disk on its command line.
    static func diskInUse(_ disk: String) -> Bool {
        guard !disk.isEmpty else { return false }
        return run("/usr/bin/pgrep", ["-f", diskPattern(disk)]) == 0
    }

    static func killDiskUsers(_ disk: String) {
        guard !disk.isEmpty else { return }
        _ = run("/usr/bin/pkill", ["-f", diskPattern(disk)])
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
    private var changes: [UUID: AnyCancellable] = [:]
    private var timer: Timer?

    func runner(for id: UUID) -> Runner {
        if let r = runners[id] { return r }
        let r = Runner(profileID: id)
        runners[id] = r
        // the launcher tells a server's own app about each change (MachineLink), after the change has landed
        if !MachineApp.active {
            changes[id] = r.objectWillChange.sink { [weak r] _ in DispatchQueue.main.async { if let r { MachineLink.send(r) } } }
        }
        return r
    }

    var active: [Runner] { runners.values.filter(\.isActive) }

    /// myLinux Apps added or took away a cloud drive (ServerApps.takeCloudRequest): saved, and a running machine
    /// restarts to attach them; its terminal reconnects, and the folders are mounted as after any start.
    private func cloudRequest(_ id: UUID, store: ProfileStore) {
        guard var q = store.profiles.first(where: { $0.id == id }), let asked = ServerApps.takeCloudRequest(q.shareDir) else { return }
        let r = runner(for: id)
        // Apps can take a Mac folder away (adding one is the Cloud Folders dialog's Add Folder…)
        let mac = q.macFolders.filter { asked.contains($0.tag) }
        let folders = CloudFolder.allCases.map(\.rawValue).filter { asked.contains($0) }
        guard folders != q.cloudFolders || mac != q.macFolders else { ServerApps.writeCloudState(q); return }
        q.cloudFolders = folders; q.macFolders = mac
        store.update(q)
        ServerApps.writeCloudState(q)
        if r.isActive || r.canStopElsewhere { r.restart(q) }
    }

    func startWatching(_ store: ProfileStore) {
        timer?.invalidate()
        let tick = { [weak self, weak store] in
            guard let self, let store else { return }
            for p in store.profiles {
                let r = self.runner(for: p.id)
                // pgrep in the background: on the main thread, every machine every 4 s, it stalled the window
                DispatchQueue.global(qos: .utility).async {
                    let inUse = Runner.diskInUse(p.appsDisk)
                    let cloudAsked = (p.isServer || p.kind.runsDesktop) && !p.shareDir.isEmpty
                        && FileManager.default.fileExists(atPath: ServerApps.cloudRequestFile(p.shareDir).path)
                    // "Sign Codex in as on the Mac" from inside the machine (CodexLogin): a request to answer, a login to clear away
                    let codexAsked = !p.shareDir.isEmpty && FileManager.default.fileExists(atPath: CodexLogin.requestFile(p.shareDir).path)
                    if !p.shareDir.isEmpty { CodexLogin.sweep(p.shareDir) }
                    DispatchQueue.main.async {
                        r.refreshExternal(inUse: inUse)
                        // Windows being installed: the steps, beside the machine's window (WindowsSetupHelp)
                        if p.kind == .windows {
                            MainActor.assumeIsolated {
                                WindowsSetupHelp.follow(p, running: inUse)
                                WindowsUnattended.follow(p, runner: r)      // an install that answers itself restarts itself at its end
                            }
                        }
                        // an Omarchy made with its first-start answers: set up when its desktop is seen
                        if p.kind == .omarchy { MainActor.assumeIsolated { OmarchyUnattended.follow(p, runner: r) } }
                        if cloudAsked { self.cloudRequest(p.id, store: store) }
                        if codexAsked { CodexLogin.answer(p) }
                    }
                }
            }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in tick() }
    }
}
