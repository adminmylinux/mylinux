import AppKit

/// What a Windows machine is told about the Mac display its window is on. `myLinux Launcher --windows-display <socket>`,
/// started by run-windows.sh beside QEMU as the clipboard bridge is, writes "scale=1" or "scale=2" (that display's
/// pixels to a point) to the virtio port dev.mylinux.host: when the window comes onto a display of the other kind, and
/// every few seconds besides (the agent inside may open the port later than this starts). windows/mylinux-agent.ps1
/// sets Windows's scaling to match. Dragged from a Retina display to another kind or back, the window keeps its size
/// (the runtime's MYLINUX_GUEST_SCALES), Windows gets half or twice the pixels, and what is in it stays as large.
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

    /// Runs until the process that started it (the script, which becomes QEMU) is gone.
    static func run(socketPath: String) -> Int32 {
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
        var last: Int?, tick = 0
        while getppid() == parent {
            if let now = scale(ofWindowOf: parent), now != last || tick % 3 == 0 {
                if now != last { log("the window is on a display with \(now) pixel\(now == 1 ? "" : "s") to a point") }
                let line = Array("scale=\(now)\n".utf8)
                if write(fd, line, line.count) < 0 { log("the port is gone"); break }
                last = now
            }
            tick += 1
            sleep(1)
        }
        close(fd)
        return 0
    }
}
