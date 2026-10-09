import AppKit

/// What a Windows machine is told about the Mac display its window is on. `myLinux Launcher --windows-display <socket>`,
/// started by run-windows.sh beside QEMU as the clipboard bridge is, writes "scale=1" or "scale=2" (that display's
/// pixels to a point) to the virtio port dev.mylinux.host: when the window comes onto a display of the other kind, and
/// every few seconds besides (the agent inside may open the port later than this starts). windows/mylinux-agent.ps1
/// sets Windows's scaling to match. Dragged from a Retina display to another kind or back, the window keeps its size
/// (the runtime's MYLINUX_GUEST_SCALES), Windows gets half or twice the pixels, and what is in it stays as large.
/// The agent answers every line with what Windows's memory is at; with a file to keep it in (the second argument), the
/// launcher's sidebar shows that figure and not what QEMU holds on the Mac.
/// CoreGraphics only: this process is no application, and AppKit's list of screens would not follow a display that
/// comes or goes.
enum WindowsDisplay {
    /// A display mode's pixels to a point: 2 on a Retina display, 1 elsewhere.
    static func scale(pixelWidth: Int, width: Int) -> Int { width > 0 && pixelWidth >= width * 2 ? 2 : 1 }

    /// For the display that has the middle of a process's largest window; nil without a window on screen.
    static func scale(ofWindowOf pid: pid_t) -> Int? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let rects = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        guard let r = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        var display = CGDirectDisplayID(0); var found: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: r.midX, y: r.midY), 1, &display, &found) == .success, found > 0,
              let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        return scale(pixelWidth: mode.pixelWidth, width: mode.width)
    }

    static func log(_ m: String) { FileHandle.standardError.write(Data("windows-display: \(m)\n".utf8)) }

    /// What Windows says its memory is at ("memory=<bytes in use>/<bytes in all>", windows/mylinux-agent.ps1's answer to
    /// every line it is sent), as the launcher's sidebar wants it: the two numbers.
    static func memory(_ line: String) -> (used: Double, total: Double)? {
        guard line.hasPrefix("memory=") else { return nil }
        let parts = line.dropFirst("memory=".count).split(separator: "/")
        guard parts.count == 2, let used = Double(parts[0]), let total = Double(parts[1]), total > 0, used >= 0, used <= total else { return nil }
        return (used, total)
    }

    /// The last figure the helper kept for a machine, when it is no older than a few of its beats (`MachineStats`).
    static func memoryFile(_ machineFolder: URL) -> URL { machineFolder.appendingPathComponent("guest-memory") }
    static func keptMemory(_ machineFolder: URL, now: Date = Date()) -> (used: Double, total: Double)? {
        let file = memoryFile(machineFolder)
        guard let at = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date, now.timeIntervalSince(at) < 20,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return memory(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs until the process that started it (the script, which becomes QEMU) is gone. A line goes to Windows every
    /// three seconds (the display's kind, or "ping" while the window is on no display): its agent answers each with its
    /// memory figure, which is kept in `statsFile` for the launcher.
    static func run(socketPath: String, statsFile: String? = nil) -> Int32 {
        let parent = getppid()
        signal(SIGPIPE, SIG_IGN)
        var fd: Int32 = -1
        let deadline = Date().addingTimeInterval(120)
        while fd < 0, Date() < deadline {                       // QEMU makes the socket once it is up
            if getppid() != parent { return 0 }
            fd = Runner.connectUnix(socketPath)
            if fd < 0 { usleep(500_000) }
        }
        guard fd >= 0 else { log("no port for the display after two minutes"); return 1 }
        if let statsFile {
            let port = fd
            Thread.detachNewThread {                            // what Windows answers, a line at a time
                var pending = Data(), chunk = [UInt8](repeating: 0, count: 512)
                while true {
                    let n = read(port, &chunk, chunk.count)
                    if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
                    pending.append(contentsOf: chunk[0..<n])
                    while let end = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        pending.removeSubrange(pending.startIndex...end)
                        if memory(line) != nil { try? (line + "\n").write(toFile: statsFile, atomically: true, encoding: .utf8) }
                    }
                    if pending.count > 4096 { pending.removeAll() }
                }
            }
        }
        var last: Int?, tick = 0
        while getppid() == parent {
            var changed = false
            if let now = scale(ofWindowOf: parent), now != last {
                log("the window is on a display with \(now) pixel\(now == 1 ? "" : "s") to a point"); last = now; changed = true
            }
            if changed || tick % 3 == 0 {
                let line = Array((last.map { "scale=\($0)" } ?? "ping").utf8) + [0x0A]
                if write(fd, line, line.count) < 0 { log("the port is gone"); break }
            }
            tick += 1
            sleep(1)
        }
        close(fd)
        if let statsFile { try? FileManager.default.removeItem(atPath: statsFile) }
        return 0
    }
}
