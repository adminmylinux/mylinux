import AppKit

/// A window the launcher opens for a machine (Cloud Folders…, Mount a Share…) goes in front of that machine's own
/// window, on its screen, and not where macOS puts a new window (the main screen): with two displays it came up on the
/// other one, out of a recording. Without the machine's window, the screen under the pointer.
enum MachineWindowPlacement {
    /// The machine's own app's largest window, in AppKit's coordinates (bottom-left origin).
    static func frame(of p: Profile) -> NSRect? {
        MachineApp.running(p).flatMap { frame(pid: $0.processIdentifier) }
    }

    /// A process's largest ordinary window on screen.
    static func frame(pid: pid_t) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let rects = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        guard let r = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        // the window server's origin is the primary screen's top left
        return NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Where `w` goes: centred on the machine's window (or the pointer's screen), kept inside that screen.
    static func place(_ w: NSWindow, for p: Profile?) {
        let target: NSRect
        if let p, let f = frame(of: p) { target = f }
        else if let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) { target = s.visibleFrame }
        else { w.center(); return }
        let middle = NSPoint(x: target.midX, y: target.midY)
        guard let vis = (NSScreen.screens.first { $0.frame.contains(middle) } ?? NSScreen.main)?.visibleFrame else { w.center(); return }
        var f = w.frame
        f.origin = NSPoint(x: middle.x - f.width / 2, y: middle.y - f.height / 2)
        f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
        w.setFrame(f, display: false)
    }
}
