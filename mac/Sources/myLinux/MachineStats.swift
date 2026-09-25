import Foundation
import Darwin

/// What the sidebar shows under a running machine: CPU, memory used of what it was given, and its disk's free space.
/// Every 3 s, off the main thread:
/// - CPU: its QEMU's share of the machine's virtual CPUs (one `ps` for all machines; -smp gives the count).
/// - Memory: what the guest itself says it uses (total minus available), from QEMU's balloon statistics on the
///   control socket (Debian, Alpine and Omarchy have the balloon device); myLinux has none, so there it is the
///   memory QEMU holds on the Mac, which is the guest's memory as far as the Mac is concerned.
/// - Disk: `df` inside a server over ssh every 30 s; otherwise the Mac's view of the disk file, the space it takes
///   (a disk file grows as the guest writes, and space the guest frees is not handed back to the Mac, so this is
///   the free space at most).
final class MachineStats: ObservableObject {
    static let shared = MachineStats()

    struct Stat: Equatable {
        var cpu: Double              // 0…1 of the machine's CPUs
        var memUsed: Double          // bytes
        var memTotal: Double
        var memFromGuest: Bool
        var diskUsed: Double
        var diskTotal: Double
        var diskFromGuest: Bool
        var memFraction: Double { memTotal > 0 ? min(1, memUsed / memTotal) : 0 }
        var diskFraction: Double { diskTotal > 0 ? min(1, diskUsed / diskTotal) : 0 }
        var diskFree: Double { max(0, diskTotal - diskUsed) }
    }

    @Published private(set) var stats: [UUID: Stat] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "mylinux.stats", qos: .utility)
    private var busy = false
    /// the balloon's statistics are switched on once per QEMU (pid)
    private var polling: Set<Int32> = []
    /// servers' disks from inside: the last answer and when it was asked
    private var guestDisk: [UUID: (used: Double, total: Double, at: Date)] = [:]

    func start(store: ProfileStore = .shared, runs: RunManager = .shared) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick(store: store, runs: runs) }
        tick(store: store, runs: runs)
    }

    private func tick(store: ProfileStore, runs: RunManager) {
        guard !busy else { return }
        let machines = store.profiles.compactMap { p -> (Profile, Runner)? in
            let r = runs.runner(for: p.id)
            return r.state == .running || r.state == .inUseElsewhere ? (p, r) : nil
        }
        if machines.isEmpty { if !stats.isEmpty { stats = [:] }; return }
        busy = true
        let sockets = Dictionary(uniqueKeysWithValues: machines.map { ($0.0.id, $0.1.qmpSocket) })
        queue.async { [weak self] in
            guard let self else { return }
            let procs = MachineStats.qemuProcesses()
            var out: [UUID: Stat] = [:]
            for (p, _) in machines {
                guard let proc = procs.first(where: { $0.command.range(of: Runner.diskPattern(p.appsDisk), options: .regularExpression) != nil }) else { continue }
                let vcpus = max(1, MachineStats.smp(proc.command) ?? 1)
                let allocated = Double(p.memoryGB) * 1_073_741_824
                var s = Stat(cpu: min(1, proc.cpu / 100 / Double(vcpus)), memUsed: min(allocated, proc.rss), memTotal: allocated,
                             memFromGuest: false, diskUsed: 0, diskTotal: 0, diskFromGuest: false)
                if p.kind != .mylinux, let socket = sockets[p.id], let m = self.balloon(socket, pid: proc.pid) {
                    s.memUsed = m.used; s.memTotal = m.total; s.memFromGuest = true
                }
                if let d = MachineStats.fileDisk(p.appsDisk) { s.diskUsed = d.used; s.diskTotal = d.total }
                if p.isServer {
                    if (self.guestDisk[p.id].map { Date().timeIntervalSince($0.at) > 30 }) ?? true, let d = MachineStats.serverDisk(p) {
                        self.guestDisk[p.id] = (d.used, d.total, Date())
                    }
                    if let d = self.guestDisk[p.id] { s.diskUsed = d.used; s.diskTotal = d.total; s.diskFromGuest = true }
                }
                out[p.id] = s
            }
            DispatchQueue.main.async {
                self.busy = false
                if self.stats != out { self.stats = out }
            }
        }
    }

    // ---- the parts ------------------------------------------------------------------------------------------------
    struct Proc { let pid: Int32; let cpu: Double; let rss: Double; let command: String }

    /// Every QEMU on the Mac: pid, CPU (percent of one core), resident memory, command line.
    static func qemuProcesses() -> [Proc] {
        guard let text = output("/bin/ps", ["-axww", "-o", "pid=,pcpu=,rss=,command="]) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard line.contains("qemu") else { return nil }
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = Double(f[2]) else { return nil }
            return Proc(pid: pid, cpu: cpu, rss: rss * 1024, command: String(f[3]))
        }
    }

    /// The virtual CPUs on a QEMU command line (-smp 4, or -smp cpus=4,…).
    static func smp(_ command: String) -> Int? {
        guard let r = command.range(of: #"-smp (cpus=)?([0-9]+)"#, options: .regularExpression) else { return nil }
        return Int(command[r].filter(\.isNumber))
    }

    /// A disk file's size and the space it takes on the Mac (it is sparse: unwritten parts take none).
    static func fileDisk(_ path: String) -> (used: Double, total: Double)? {
        var st = stat()
        guard !path.isEmpty, stat(path, &st) == 0, st.st_size > 0 else { return nil }
        return (Double(st.st_blocks) * 512, Double(st.st_size))
    }

    /// A server's root file system, from inside (`df -Pk /`).
    static func serverDisk(_ p: Profile) -> (used: Double, total: Double)? {
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3"] + SshTerminal.arguments(for: p.terminalProfile) + ["df", "-Pk", "/"]
        guard let text = output("/usr/bin/ssh", args, timeout: 8),
              let line = text.split(separator: "\n").last?.split(separator: " ", omittingEmptySubsequences: true), line.count >= 4,
              let total = Double(line[1]), let used = Double(line[2]) else { return nil }
        return (used * 1024, total * 1024)
    }

    /// The guest's own memory numbers, from QEMU's balloon device (statistics switched on the first time).
    private func balloon(_ socket: String, pid: Int32) -> (used: Double, total: Double)? {
        guard FileManager.default.fileExists(atPath: socket) else { return nil }
        let fd = Runner.connectUnix(socket)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8]()
        func readLine() -> String? {
            var b: UInt8 = 0
            while Darwin.read(fd, &b, 1) == 1 {
                if b == 0x0A { defer { buffer = [] }; return String(decoding: buffer, as: UTF8.self) }
                buffer.append(b)
            }
            return nil
        }
        /// a command's reply, skipping QEMU's events
        func call(_ json: String) -> [String: Any]? {
            guard json.withCString({ Darwin.write(fd, $0, strlen($0)) }) > 0 else { return nil }
            for _ in 0..<20 {
                guard let l = readLine(), let d = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { return nil }
                if d["return"] != nil || d["error"] != nil { return d }
            }
            return nil
        }
        guard readLine() != nil, call(#"{"execute":"qmp_capabilities"}"# + "\n") != nil else { return nil }
        // the balloon device: its path, found once per QEMU among the devices without an id
        guard let path = balloonPaths[pid] ?? balloonPath(call) else { return nil }
        balloonPaths[pid] = path
        if !polling.contains(pid) {
            _ = call(#"{"execute":"qom-set","arguments":{"path":"\#(path)","property":"guest-stats-polling-interval","value":2}}"# + "\n")
            polling.insert(pid)
            return nil                     // the first numbers come with the next tick
        }
        guard let r = call(#"{"execute":"qom-get","arguments":{"path":"\#(path)","property":"guest-stats"}}"# + "\n")?["return"] as? [String: Any],
              let s = r["stats"] as? [String: Any],
              let total = (s["stat-total-memory"] as? NSNumber)?.doubleValue, total > 0 else { return nil }
        let available = (s["stat-available-memory"] as? NSNumber)?.doubleValue ?? (s["stat-free-memory"] as? NSNumber)?.doubleValue
        guard let available, available >= 0, available <= total else { return nil }
        return (total - available, total)
    }

    private var balloonPaths: [Int32: String] = [:]
    private func balloonPath(_ call: (String) -> [String: Any]?) -> String? {
        for base in ["/machine/peripheral-anon", "/machine/peripheral"] {
            guard let list = call(#"{"execute":"qom-list","arguments":{"path":"\#(base)"}}"# + "\n")?["return"] as? [[String: Any]] else { continue }
            if let d = list.first(where: { ($0["type"] as? String) == "child<virtio-balloon-pci>" }), let name = d["name"] as? String {
                return "\(base)/\(name)"
            }
        }
        return nil
    }

    @discardableResult
    static func output(_ tool: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Paths.toolPath; p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let reader = DispatchQueue(label: "mylinux.stats.read")
        let done = DispatchSemaphore(value: 0)
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
