// vncspike: libvncclient decoding into an IOSurface shown by a CALayer, with numbers on screen.
// Usage: vncspike host[:port] [username] [ca.pem] [certificate name]   (a username means VeNCrypt with a password prompt)
// Keys while connected: everything goes to the remote except ⌘ combinations; F2 toggles the 1:1 (Retina) window
// size; the "Full grab" button installs an HID-level event tap (asks for Accessibility) and Ctrl+Option+G releases it.
import AppKit
import IOSurface
import QuartzCore
import Carbon.HIToolbox
import CVncClient

// ---- the connection: libvncclient on its own thread ----------------------------------------------------------------
final class VncClient {
    var host = "", port: Int32 = 5900, username = "", password = "", caFile = "", verifyName = ""   // the certificate's name when connecting by IP
    private(set) var surface: IOSurface?
    private(set) var width = 0, height = 0
    var onResize: ((Int, Int) -> Void)?
    var onFrame: ((CGRect) -> Void)?                // a finished update (damage in remote pixels)
    var onState: ((String) -> Void)?
    private var thread: Thread?
    private var client: UnsafeMutablePointer<rfbClient>?
    private let lock = NSLock()
    private var queue: [(UInt32, Bool, Int, Int, Int32, Int)] = []   // keysym, down, x, y, mask, kind (0 key, 1 pointer)
    private var quit = false
    private var damage = CGRect.null
    private var staging: UnsafeMutablePointer<UInt8>?           // libvncclient's buffer when the surface stride differs
    var direct = true
    // stats
    var updates = 0, rects = 0, decodeNs: UInt64 = 0

    private static func selfOf(_ c: UnsafeMutablePointer<rfbClient>?) -> VncClient {
        Unmanaged<VncClient>.fromOpaque(rfbClientGetClientData(c, UnsafeMutableRawPointer(bitPattern: 1))).takeUnretainedValue()
    }

    func start() {
        thread = Thread { [self] in run() }
        thread!.name = "vnc"; thread!.start()
    }
    func stop() { quit = true }

    func post(key: UInt32, down: Bool) { lock.lock(); queue.append((key, down, 0, 0, 0, 0)); lock.unlock() }
    func post(pointer x: Int, _ y: Int, mask: Int32) { lock.lock(); queue.append((0, false, x, y, mask, 1)); lock.unlock() }

    private func run() {
        guard let c = rfbGetClient(8, 3, 4) else { onState?("rfbGetClient failed"); return }
        client = c
        rfbClientSetClientData(c, UnsafeMutableRawPointer(bitPattern: 1), Unmanaged.passUnretained(self).toOpaque())
        c.pointee.MallocFrameBuffer = { c in
            let s = VncClient.selfOf(c)
            let w = Int(c!.pointee.width), h = Int(c!.pointee.height)
            let surf = IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4, .pixelFormat: UInt32(0x42475241) /* BGRA */])!
            IOSurfaceLock(surf, [], nil)
            memset(surf.baseAddress, 0, surf.allocationSize)
            IOSurfaceUnlock(surf, [], nil)
            s.surface = surf; s.width = w; s.height = h
            c!.pointee.frameBuffer = surf.baseAddress.assumingMemoryBound(to: UInt8.self)
            c!.pointee.format.bitsPerPixel = 32; c!.pointee.format.depth = 24; c!.pointee.format.trueColour = 1; c!.pointee.format.bigEndian = 0
            c!.pointee.format.redShift = 16; c!.pointee.format.greenShift = 8; c!.pointee.format.blueShift = 0
            c!.pointee.format.redMax = 255; c!.pointee.format.greenMax = 255; c!.pointee.format.blueMax = 255
            SetFormatAndEncodings(c)
            // libvncclient writes rows width*4 apart; when the surface's rows are padded, decode into a staging
            // buffer and copy the damaged rectangles (the direct path is zero-copy)
            s.direct = surf.bytesPerRow == w * 4
            if !s.direct {
                s.staging?.deallocate()
                s.staging = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
                c!.pointee.frameBuffer = s.staging
            }
            NSLog("framebuffer %dx%d, surface stride %d (%@)", w, h, surf.bytesPerRow, s.direct ? "direct" : "staged copy")
            DispatchQueue.main.async { s.onResize?(w, h) }
            return 1
        }
        c.pointee.GotFrameBufferUpdate = { c, x, y, w, h in
            let s = VncClient.selfOf(c); s.rects += 1
            s.damage = s.damage.union(CGRect(x: Int(x), y: Int(y), width: Int(w), height: Int(h)))
        }
        c.pointee.FinishedFrameBufferUpdate = { c in
            let s = VncClient.selfOf(c); s.updates += 1
            let d = s.damage; s.damage = .null
            if !s.direct, let surf = s.surface, let src = s.staging, !d.isNull {
                let r = d.intersection(CGRect(x: 0, y: 0, width: s.width, height: s.height)).integral
                let dst = surf.baseAddress.assumingMemoryBound(to: UInt8.self), stride = surf.bytesPerRow
                for y in Int(r.minY)..<Int(r.maxY) {
                    memcpy(dst + y * stride + Int(r.minX) * 4, src + (y * s.width + Int(r.minX)) * 4, Int(r.width) * 4)
                }
            }
            if !d.isNull { DispatchQueue.main.async { s.onFrame?(d) } }
        }
        c.pointee.GetPassword = { c in strdup(VncClient.selfOf(c).password) }
        c.pointee.GetCredential = { c, type in
            let s = VncClient.selfOf(c)
            let cred = calloc(1, MemoryLayout<rfbCredential>.size)!.assumingMemoryBound(to: rfbCredential.self)
            if type == rfbCredentialTypeUser {
                cred.pointee.userCredential.username = strdup(s.username); cred.pointee.userCredential.password = strdup(s.password)
            } else {
                if s.caFile.isEmpty { free(cred); return nil }
                cred.pointee.x509Credential.x509CACertFile = strdup(s.caFile)
                cred.pointee.x509Credential.x509CrlVerifyMode = UInt8(rfbX509CrlVerifyNone)
            }
            return cred
        }
        c.pointee.canHandleNewFBSize = 1
        c.pointee.serverHost = strdup(host); c.pointee.serverPort = port
        c.pointee.appData.encodingsString = UnsafePointer(strdup("tight zrle copyrect hextile zlib raw"))
        c.pointee.appData.enableJPEG = 1; c.pointee.appData.qualityLevel = 7; c.pointee.appData.compressLevel = 3
        c.pointee.appData.useRemoteCursor = 0
        var schemes: [UInt32] = [UInt32(rfbVeNCrypt), UInt32(rfbVncAuth), UInt32(rfbNoAuth), 0]
        SetClientAuthSchemes(c, &schemes, -1)
        onState?("connecting to \(host):\(port)")
        if !verifyName.isEmpty {
            // connect by address first, then verify the certificate against the name it carries (libvncclient checks
            // serverHost); listenSpecified makes rfbInitClient skip its own connect
            if ConnectToRFBServer(c, host, port) == 0 { client = nil; onState?("cannot connect"); return }
            c.pointee.listenSpecified = 1
            c.pointee.serverHost = strdup(verifyName)
        }
        if rfbInitClient(c, nil, nil) == 0 { client = nil; onState?("connection failed (see stderr)"); return }
        onState?("connected \(width)×\(height)")
        while !quit {
            let r = WaitForMessage(c, 5000)
            if r < 0 { break }
            if r > 0 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                if let surf = surface { IOSurfaceLock(surf, [], nil) }
                let ok = HandleRFBServerMessage(c)
                if let surf = surface { IOSurfaceUnlock(surf, [], nil) }
                decodeNs += DispatchTime.now().uptimeNanoseconds - t0
                if ok == 0 { break }
            }
            lock.lock(); let ev = queue; queue.removeAll(); lock.unlock()
            for e in ev {
                if e.5 == 0 { SendKeyEvent(c, e.0, e.1 ? 1 : 0) } else { SendPointerEvent(c, Int32(e.2), Int32(e.3), e.4) }
            }
        }
        c.pointee.frameBuffer = nil
        rfbClientCleanup(c); client = nil
        onState?("disconnected")
    }
}

// ---- the view: an IOSurface-backed layer, mouse and keys to the remote ------------------------------------------------
final class VncView: NSView {
    let vnc: VncClient
    let picture = CALayer()
    var mask: Int32 = 0
    var lastKeyAt: UInt64 = 0
    var latencyMs: Double = 0, latencySamples = 0, latencySum: Double = 0
    var grabTap: CFMachPort?
    var grabbing = false

    init(vnc: VncClient) {
        self.vnc = vnc
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        wantsLayer = true
        layer!.backgroundColor = NSColor.black.cgColor
        picture.contentsGravity = .resizeAspect
        picture.minificationFilter = .trilinear
        picture.magnificationFilter = .nearest
        layer!.addSublayer(picture)
        vnc.onResize = { [weak self] w, h in guard let self else { return }; self.picture.contents = self.vnc.surface; self.relayout() }
        vnc.onFrame = { [weak self] _ in
            guard let self, let surf = self.vnc.surface else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.picture.contents = nil; self.picture.contents = surf         // re-commit: the surface changed underneath
            CATransaction.commit()
            if self.lastKeyAt != 0 {
                let dt = Double(DispatchTime.now().uptimeNanoseconds - self.lastKeyAt) / 1e6
                self.latencyMs = dt; self.latencySum += dt; self.latencySamples += 1; self.lastKeyAt = 0
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); relayout() }
    func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = bounds
        picture.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }
    /// the remote framebuffer rect on screen (resizeAspect geometry)
    var target: CGRect {
        guard vnc.width > 0 else { return bounds }
        let s = min(bounds.width / CGFloat(vnc.width), bounds.height / CGFloat(vnc.height))
        let w = CGFloat(vnc.width) * s, h = CGFloat(vnc.height) * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
    func remote(_ p: NSPoint) -> (Int, Int) {
        let t = target
        let x = Int((p.x - t.minX) * CGFloat(vnc.width) / t.width), y = Int((t.maxY - p.y) * CGFloat(vnc.height) / t.height)
        return (max(0, min(vnc.width - 1, x)), max(0, min(vnc.height - 1, y)))
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    func pointer(_ e: NSEvent) { let (x, y) = remote(convert(e.locationInWindow, from: nil)); vnc.post(pointer: x, y, mask: mask) }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); mask |= 1; pointer(e) }
    override func mouseUp(with e: NSEvent) { mask &= ~1; pointer(e) }
    override func rightMouseDown(with e: NSEvent) { mask |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { mask &= ~4; pointer(e) }
    override func otherMouseDown(with e: NSEvent) { mask |= 2; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { mask &= ~2; pointer(e) }
    override func scrollWheel(with e: NSEvent) {
        let (x, y) = remote(convert(e.locationInWindow, from: nil))
        let steps = Int(abs(e.scrollingDeltaY) / (e.hasPreciseScrollingDeltas ? 20 : 1))
        for _ in 0..<max(1, min(steps, 5)) { let b: Int32 = e.scrollingDeltaY > 0 ? 8 : 16; vnc.post(pointer: x, y, mask: mask | b); vnc.post(pointer: x, y, mask: mask) }
    }

    // keys: Mac key code -> X11 keysym, layout-aware through the event's characters (ignoring modifiers)
    static let special: [UInt16: UInt32] = [
        36: 0xff0d, 76: 0xff8d, 51: 0xff08, 48: 0xff09, 53: 0xff1b, 117: 0xffff, 123: 0xff51, 126: 0xff52, 124: 0xff53, 125: 0xff54,
        115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56, 122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1, 96: 0xffc2, 97: 0xffc3,
        98: 0xffc4, 100: 0xffc5, 101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9,
        56: 0xffe1, 60: 0xffe2, 59: 0xffe3, 62: 0xffe4, 58: 0xffe9, 61: 0xffea, 55: 0xffeb, 54: 0xffec, 57: 0xffe5,
    ]
    func keysym(_ e: NSEvent) -> UInt32? {
        if let k = VncView.special[e.keyCode] { return k }
        guard let s = e.charactersIgnoringModifiers, let u = s.unicodeScalars.first else { return nil }
        var v = u.value
        if e.modifierFlags.contains(.shift), let up = e.characters?.unicodeScalars.first { v = up.value }   // shifted glyph
        if v < 0x20 { return nil }
        return v < 0x100 ? v : 0x01000000 + v
    }
    override func keyDown(with e: NSEvent) { send(e, down: true) }
    override func keyUp(with e: NSEvent) { send(e, down: false) }
    func send(_ e: NSEvent, down: Bool) {
        // Option acts as the remote's Super key (Option-as-Super mode); ⌘ combinations stay with the Mac unless grabbing
        if e.modifierFlags.contains(.command) && !grabbing { nextResponder?.keyDown(with: e); return }
        guard let k = keysym(e) else { return }
        if down { lastKeyAt = DispatchTime.now().uptimeNanoseconds }
        vnc.post(key: k, down: down)
    }
    var lastFlags: NSEvent.ModifierFlags = []
    override func flagsChanged(with e: NSEvent) {
        let f = e.modifierFlags
        let pairs: [(NSEvent.ModifierFlags, UInt32)] = [(.shift, 0xffe1), (.control, 0xffe3), (.option, 0xffeb) /* Option -> Super_L */, (.command, 0xffe9) /* ⌘ -> Alt when grabbed */]
        for (flag, sym) in pairs where f.contains(flag) != lastFlags.contains(flag) {
            if flag == .command && !grabbing { continue }
            vnc.post(key: sym, down: f.contains(flag))
        }
        lastFlags = f
    }

    // ---- the full grab: an HID-level tap that hands every key to the remote while our window is key -------------------
    func toggleGrab() {
        if grabbing { releaseGrab(); return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { NSLog("grab: Accessibility permission not granted yet"); return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
            let view = Unmanaged<VncView>.fromOpaque(refcon!).takeUnretainedValue()
            guard view.grabbing, view.window?.isKeyWindow == true else { return Unmanaged.passUnretained(event) }
            let flags = event.flags, code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // Ctrl+Option+G releases
            if type == .keyDown && code == 5 && flags.contains(.maskControl) && flags.contains(.maskAlternate) { DispatchQueue.main.async { view.releaseGrab() }; return nil }
            if let ns = NSEvent(cgEvent: event) {
                DispatchQueue.main.async {
                    if type == .flagsChanged { view.flagsChanged(with: ns) } else { view.send(ns, down: type == .keyDown) }
                }
            }
            return nil                                              // swallowed: macOS never sees ⌘Tab, ⌘Space, ...
        }, userInfo: me) else { NSLog("grab: tap could not be created"); return }
        grabTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        grabbing = true
        NSLog("grab: on (Ctrl+Option+G releases)")
    }
    func releaseGrab() {
        if let tap = grabTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        grabTap = nil; grabbing = false
        NSLog("grab: off")
    }
}

// ---- app --------------------------------------------------------------------------------------------------------------
let args = CommandLine.arguments.dropFirst()
guard let target = args.first else { print("usage: vncspike host[:port] [username] [ca.pem]"); exit(2) }
let vnc = VncClient()
if let c = target.lastIndex(of: ":"), let p = Int32(target[target.index(after: c)...]) { vnc.host = String(target[..<c]); vnc.port = p } else { vnc.host = target }
vnc.username = args.dropFirst().first ?? ""
vnc.caFile = args.dropFirst(2).first ?? ""
vnc.verifyName = args.dropFirst(3).first ?? ""

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.title = "vncspike — \(vnc.host)"
let view = VncView(vnc: vnc)
window.contentView = view
let hud = NSTextField(labelWithString: "…")
hud.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular); hud.textColor = .white
hud.backgroundColor = NSColor.black.withAlphaComponent(0.6); hud.drawsBackground = true
hud.frame = NSRect(x: 8, y: 8, width: 900, height: 18); hud.autoresizingMask = [.maxXMargin, .maxYMargin]
view.addSubview(hud)
let grabButton = NSButton(title: "Full grab", target: nil, action: nil)
grabButton.frame = NSRect(x: 8, y: 30, width: 90, height: 24); grabButton.autoresizingMask = [.maxXMargin, .maxYMargin]
final class Actions: NSObject { @objc func grab(_: Any?) { view.toggleGrab() } }
let actions = Actions(); grabButton.target = actions; grabButton.action = #selector(Actions.grab(_:))
view.addSubview(grabButton)
window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)

vnc.onState = { s in DispatchQueue.main.async { hud.stringValue = s; NSLog("%@", s) } }
if !vnc.username.isEmpty {
    let alert = NSAlert(); alert.messageText = "Password for \(vnc.username)@\(vnc.host)"
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); alert.accessoryView = field
    alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    if alert.runModal() != .alertFirstButtonReturn { exit(0) }
    vnc.password = field.stringValue
}
vnc.start()

// numbers once a second: updates/s, rects/s, decode ms per second of wall time, CPU %, last/avg key->picture latency
var lastUpdates = 0, lastRects = 0, lastDecode: UInt64 = 0, lastCpu = 0.0, tick = 0
func cpuSeconds() -> Double { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6 }
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    let u = vnc.updates - lastUpdates, r = vnc.rects - lastRects, d = Double(vnc.decodeNs - lastDecode) / 1e6, cpu = cpuSeconds()
    lastUpdates = vnc.updates; lastRects = vnc.rects; lastDecode = vnc.decodeNs
    let avg = view.latencySamples > 0 ? view.latencySum / Double(view.latencySamples) : 0
    hud.stringValue = String(format: "%@  %d upd/s  %d rects/s  decode %.0f ms/s  cpu %.0f%%  key→picture last %.0f ms avg %.0f ms  grab %@  (F2: 1:1 size)",
                             vnc.width > 0 ? "\(vnc.width)×\(vnc.height)" : "…", u, r, d, (cpu - lastCpu) * 100, view.latencyMs, avg, view.grabbing ? "ON" : "off")
    lastCpu = cpu
    tick += 1
    if tick % 5 == 0 { NSLog("%@", hud.stringValue) }          // the numbers in the log too
}
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    if e.keyCode == 120 && vnc.width > 0 {        // F2: window at one remote pixel per Mac pixel
        let s = window.backingScaleFactor
        window.setContentSize(NSSize(width: CGFloat(vnc.width) / s, height: CGFloat(vnc.height) / s)); return nil
    }
    return e
}
app.run()
