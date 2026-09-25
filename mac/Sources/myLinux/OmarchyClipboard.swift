import AppKit
import CryptoKit
import Foundation

/// The Mac side of Omarchy's clipboard bridge, as a helper mode of the launcher binary
/// (`myLinux Launcher --omarchy-clipboard <socket>`), so it needs no python3. Omarchy's image runs an agent
/// (omarchy-native-clipboard-bridge, from the Try Omarchy project) once a virtio serial port named
/// dev.tryomarchy.clipboard exists; run-omarchy.sh backs that port with a unix socket and starts this beside QEMU.
/// One JSON object per line travels each way:
///     {"type": "clipboard", "format": "text/plain;charset=utf-8" | "image/png", "data": "<base64>"}
/// and the guest asks {"type": "sync"} for the Mac's clipboard when it comes up. Echoes (a side announcing what it was
/// just given) are recognised by fingerprint, as the guest does it. It exits when QEMU closes the socket or the process
/// that started it (the script, which becomes QEMU) is gone. Replaces tools/omarchy-clipboard.py.
enum OmarchyClipboard {
    static let text = "text/plain;charset=utf-8", png = "image/png"
    static let formats: Set<String> = [text, png]
    static let maxPayload = 16 * 1024 * 1024
    static let maxLine = maxPayload * 4 / 3 + 4096
    static let echoWindow: TimeInterval = 2

    enum Message: Equatable { case sync, clipboard(String, Data) }

    static func fingerprint(_ mime: String, _ payload: Data) -> String {
        var h = SHA256(); h.update(data: Data(mime.utf8)); h.update(data: Data([0])); h.update(data: payload)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func encode(_ mime: String, _ payload: Data) -> Data {
        let object: [String: String] = ["type": "clipboard", "format": mime, "data": payload.base64EncodedString()]
        var d = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        d.append(0x0a); return d
    }
    /// A guest line: a sync request, a clipboard change, or nil for anything to ignore.
    static func decode(_ line: Data) -> Message? {
        guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if m["type"] as? String == "sync" { return .sync }
        guard m["type"] as? String == "clipboard", Set(m.keys) == ["type", "format", "data"],
              let mime = m["format"] as? String, formats.contains(mime), let b64 = m["data"] as? String,
              let payload = Data(base64Encoded: b64), !payload.isEmpty, payload.count <= maxPayload else { return nil }
        if mime == text, String(data: payload, encoding: .utf8) == nil { return nil }
        return .clipboard(mime, payload)
    }

    /// Echo-safe two-way state, the mirror image of the guest agent's: a marker protects only content still on the
    /// other side, so accepting a change in one direction clears the other direction's marker; a short expiry backs it up.
    final class Sync {
        let send: (Data) -> Void
        let copy: (String, Data) -> Void
        let clock: () -> TimeInterval
        private var lastFromGuest: (String, TimeInterval)?
        private var lastFromMac: (String, TimeInterval)?
        private var macNow: (String, Data)?

        init(send: @escaping (Data) -> Void, copy: @escaping (String, Data) -> Void, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
            self.send = send; self.copy = copy; self.clock = clock
        }
        private func echo(_ marker: (String, TimeInterval)?, _ key: String, _ now: TimeInterval) -> Bool {
            guard let marker else { return false }
            return marker.0 == key && now - marker.1 <= OmarchyClipboard.echoWindow
        }
        @discardableResult func macChanged(_ mime: String, _ payload: Data) -> Bool {
            guard OmarchyClipboard.formats.contains(mime), !payload.isEmpty, payload.count <= OmarchyClipboard.maxPayload else { return false }
            macNow = (mime, payload)
            let key = OmarchyClipboard.fingerprint(mime, payload), now = clock()
            if echo(lastFromGuest, key, now) { return false }
            lastFromMac = (key, now); lastFromGuest = nil
            send(OmarchyClipboard.encode(mime, payload)); return true
        }
        @discardableResult func guestChanged(_ mime: String, _ payload: Data) -> Bool {
            let key = OmarchyClipboard.fingerprint(mime, payload), now = clock()
            if echo(lastFromMac, key, now) { return false }
            lastFromGuest = (key, now); lastFromMac = nil
            copy(mime, payload); return true
        }
        @discardableResult func syncRequested() -> Bool {
            guard let (m, p) = macNow else { return false }
            send(OmarchyClipboard.encode(m, p)); return true
        }
    }

    // ---- the pasteboard ----------------------------------------------------------------------------------------
    /// What the Mac pasteboard holds, as the guest wants it: PNG when there is an image (TIFF converted), else text.
    static func readPasteboard(_ pb: NSPasteboard = .general) -> (String, Data)? {
        if let d = pb.data(forType: .png), !d.isEmpty { return (png, d) }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let d = rep.representation(using: .png, properties: [:]) { return (png, d) }
        if let s = pb.string(forType: .string), !s.isEmpty { return (text, Data(s.utf8)) }
        return nil
    }
    static func writePasteboard(_ mime: String, _ payload: Data, _ pb: NSPasteboard = .general) {
        pb.clearContents()
        if mime == png { pb.setData(payload, forType: .png) }
        else if let s = String(data: payload, encoding: .utf8) { pb.setString(s, forType: .string) }
    }

    // ---- the helper process ------------------------------------------------------------------------------------
    static func log(_ m: String) { FileHandle.standardError.write(Data("omarchy-clipboard: \(m)\n".utf8)) }

    /// Connects to QEMU's socket (it appears once QEMU is up), for up to two minutes, while the starter lives.
    static func connect(_ path: String, parent: pid_t) -> Int32? {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if getppid() != parent { log("the machine ended before its clipboard port appeared"); return nil }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
            if ok { return fd }
            close(fd); usleep(500_000)
        }
        log("no clipboard port after two minutes"); return nil
    }

    /// The bridge's loop: the socket and the pasteboard, a quarter-second tick. Returns the exit status.
    static func run(socketPath: String) -> Int32 {
        let parent = getppid()
        guard let fd = connect(socketPath, parent: parent) else { return 1 }
        defer { close(fd); unlink(socketPath) }
        let sync = Sync(send: { data in
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { if errno == EINTR { continue }; return }
                    off += n
                }
            }
        }, copy: { mime, payload in writePasteboard(mime, payload) })
        let pb = NSPasteboard.general
        var lastChange = -1
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if getppid() != parent { return 0 }                                // QEMU is gone
            // the Mac side: a new pasteboard generation
            if pb.changeCount != lastChange {
                lastChange = pb.changeCount
                if let (mime, payload) = readPasteboard(pb) {
                    if payload.count <= maxPayload { sync.macChanged(mime, payload) } else { log("Mac clipboard exceeds the size limit; skipping") }
                }
            }
            // the guest side: whatever arrived in the next quarter second
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 250)
            if r < 0 { if errno == EINTR { continue }; log("poll failed"); return 1 }
            if r == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return 0 }                                              // QEMU closed the port
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; log("read failed"); return 1 }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxLine { log("guest clipboard message exceeds the size limit"); return 1 }
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                switch decode(Data(line)) {
                case .sync: sync.syncRequested()
                case .clipboard(let mime, let payload):
                    sync.guestChanged(mime, payload)
                    lastChange = pb.changeCount                                 // our own write is not a Mac change to send back
                case nil: log("ignoring an invalid line from the guest")
                }
            }
        }
    }
}
