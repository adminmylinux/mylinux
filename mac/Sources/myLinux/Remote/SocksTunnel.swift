import Foundation

/// A SOCKS5 proxy on 127.0.0.1 that leads into a machine: `ssh -N -D` over the machine's own connection. Whatever
/// goes through it sees the network as the machine does, so the browser pane can open the machine's localhost.
final class SocksTunnel {
    let port: UInt16
    private var process: Process?
    private let profile: RemoteProfile

    init(profile: RemoteProfile) {
        self.profile = profile
        port = SocksTunnel.freePort()
    }

    /// Starts ssh and calls `ready` on the main thread once the port answers (or with false after ten seconds).
    func start(ready: @escaping (Bool) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-N", "-D", "127.0.0.1:\(port)", "-o", "ExitOnForwardFailure=yes"] + SshTerminal.arguments(for: profile)
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Paths.toolPath
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice; proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { ready(false); return }
        process = proc
        let port = self.port
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if !proc.isRunning { break }
                if SocksTunnel.answers(port) { DispatchQueue.main.async { ready(true) }; return }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async { ready(false) }
        }
    }

    func stop() { process?.terminate(); process = nil }
    var isRunning: Bool { process?.isRunning ?? false }

    /// A port nobody listens on right now: bind to 0, read what the system chose, let it go.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { return 1080 }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func answers(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = port.bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}

/// One of the machine's own ports on a port of this Mac: `ssh -N -L`. WebKit sends localhost addresses straight to
/// the Mac whatever the proxy says, so the browser pane opens the machine's localhost:3000 as 127.0.0.1:<this port>.
final class PortForward {
    let guestPort: Int
    let macPort: UInt16
    private var process: Process?

    init(profile: RemoteProfile, guestPort: Int) {
        self.guestPort = guestPort
        macPort = SocksTunnel.freePort()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ["-N", "-L", "127.0.0.1:\(macPort):127.0.0.1:\(guestPort)", "-o", "ExitOnForwardFailure=yes"] + SshTerminal.arguments(for: profile)
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Paths.toolPath
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice; proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil { process = proc }
    }

    /// Calls `ready` on the main thread once the Mac port answers, or with false after ten seconds.
    func whenReady(_ ready: @escaping (Bool) -> Void) {
        guard let proc = process else { ready(false); return }
        let port = macPort
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && proc.isRunning {
                if SocksTunnel.answers(port) { DispatchQueue.main.async { ready(true) }; return }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async { ready(false) }
        }
    }

    var isRunning: Bool { process?.isRunning ?? false }
    func stop() { process?.terminate(); process = nil }
}
