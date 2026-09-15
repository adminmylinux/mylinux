import AppKit
import QuartzCore

/// The picture of a VNC connection and its input: an IOSurface-backed layer, zoom that follows the pointer (as in
/// the myLinux viewer), mouse, wheel with momentum, and keys according to the profile's keyboard mode.
final class VncView: NSView {
    let conn: VncConnection
    var keyboard: RemoteProfile.Keyboard { didSet { if keyboard != .all { KeyboardGrab.shared.stop(); grabbing = false }; onGrabChanged?() } }
    private(set) var grabbing = false
    var onGrabChanged: (() -> Void)?
    private let picture = CALayer()
    private var mask: Int32 = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    // zoom: 1 = fit; larger magnifies and the view follows the pointer
    var zoom: CGFloat = 1 { didSet { zoom = max(0.25, min(8, zoom)); relayout(); onZoomChanged?() } }
    var onZoomChanged: (() -> Void)?
    private var pan = CGPoint(x: 0.5, y: 0.5)
    // latency: keystroke to changed picture
    private(set) var latencyMs = 0.0, latencySamples = 0, latencySum = 0.0
    private var lastKeyAt: UInt64 = 0

    init(conn: VncConnection, keyboard: RemoteProfile.Keyboard) {
        self.conn = conn; self.keyboard = keyboard
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        wantsLayer = true
        layer!.backgroundColor = NSColor.black.cgColor
        picture.contentsGravity = .resize
        picture.minificationFilter = .trilinear; picture.magnificationFilter = .nearest
        layer!.addSublayer(picture)
        conn.onResize = { [weak self] _, _ in guard let self else { return }; self.picture.contents = self.conn.surface; self.relayout() }
        conn.onFrame = { [weak self] _ in
            guard let self, let surf = self.conn.surface else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.picture.contents = nil; self.picture.contents = surf
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
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); relayout() }

    // ---- geometry ----
    /// the fitted size, times zoom; centred while it fits, else the pan fraction chooses the visible part
    var target: CGRect {
        guard conn.width > 0 else { return bounds }
        let fit = min(bounds.width / CGFloat(conn.width), bounds.height / CGFloat(conn.height))
        let w = CGFloat(conn.width) * fit * zoom, h = CGFloat(conn.height) * fit * zoom
        let x = w <= bounds.width ? (bounds.width - w) / 2 : -(w - bounds.width) * pan.x
        let y = h <= bounds.height ? (bounds.height - h) / 2 : -(h - bounds.height) * (1 - pan.y)   // flipped y
        return CGRect(x: x, y: y, width: w, height: h)
    }
    /// Mac points per remote pixel
    var displayScale: CGFloat { conn.width > 0 ? target.width / CGFloat(conn.width) : 1 }
    /// one remote pixel per Mac pixel
    func zoomToPixels() {
        guard conn.width > 0, bounds.width > 0 else { return }
        let fit = min(bounds.width / CGFloat(conn.width), bounds.height / CGFloat(conn.height))
        let backing = window?.backingScaleFactor ?? 1
        zoom = 1 / (fit * backing)
    }
    func zoomStep(_ dir: Int) {
        let steps: [CGFloat] = [1, 1.25, 1.5, 2, 3, 4]
        if zoom < 0.999 { zoom = dir > 0 ? 1 : zoom; return }
        var i = 0; for (k, s) in steps.enumerated() where s <= zoom + 0.001 { i = k }
        zoom = steps[max(0, min(steps.count - 1, i + dir))]
    }
    private func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = target
        picture.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }
    private func follow(_ p: NSPoint) {
        guard zoom > 1, bounds.width > 0 else { return }
        let m: CGFloat = 40
        let np = CGPoint(x: max(0, min(1, (p.x - m) / max(1, bounds.width - 2 * m))), y: max(0, min(1, (p.y - m) / max(1, bounds.height - 2 * m))))
        if abs(np.x - pan.x) + abs(np.y - pan.y) < 0.002 { return }
        pan = np; relayout()
    }
    func remote(_ p: NSPoint) -> (Int, Int) {
        let t = target
        guard conn.width > 0, t.width > 0 else { return (0, 0) }
        let x = Int((p.x - t.minX) * CGFloat(conn.width) / t.width), y = Int((t.maxY - p.y) * CGFloat(conn.height) / t.height)
        return (max(0, min(conn.width - 1, x)), max(0, min(conn.height - 1, y)))
    }

    // ---- mouse ----
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func pointer(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil); follow(p)
        let (x, y) = remote(p); conn.send(pointer: x, y, mask: mask)
    }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); mask |= 1; pointer(e) }
    override func mouseUp(with e: NSEvent) { mask &= ~1; pointer(e) }
    override func rightMouseDown(with e: NSEvent) { mask |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { mask &= ~4; pointer(e) }
    override func otherMouseDown(with e: NSEvent) { mask |= 2; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { mask &= ~2; pointer(e) }
    private var wheelRest = CGPoint.zero
    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) && e.hasPreciseScrollingDeltas { zoom *= 1 + e.scrollingDeltaY / 200; return }   // ⌘+trackpad zooms
        let (x, y) = remote(convert(e.locationInWindow, from: nil))
        // one RFB wheel click per notch; precise (trackpad) deltas accumulate to clicks of ~30 points
        var dy = e.scrollingDeltaY, dx = e.scrollingDeltaX
        if e.hasPreciseScrollingDeltas { wheelRest.y += dy; wheelRest.x += dx; dy = (wheelRest.y / 30).rounded(.towardZero); dx = (wheelRest.x / 30).rounded(.towardZero); wheelRest.y -= dy * 30; wheelRest.x -= dx * 30 }
        for _ in 0..<Int(min(8, abs(dy))) { let b: Int32 = dy > 0 ? 8 : 16; conn.send(pointer: x, y, mask: mask | b); conn.send(pointer: x, y, mask: mask) }
        for _ in 0..<Int(min(8, abs(dx))) { let b: Int32 = dx > 0 ? 32 : 64; conn.send(pointer: x, y, mask: mask | b); conn.send(pointer: x, y, mask: mask) }
    }
    override func magnify(with e: NSEvent) { zoom *= 1 + e.magnification }

    // ---- keys ----
    /// Delivers a key event to the remote under the current mode; returns false when the Mac should have it.
    @discardableResult
    func handle(_ e: NSEvent) -> Bool {
        if e.type == .flagsChanged { flags(e); return true }
        let cmd = e.modifierFlags.contains(.command)
        if cmd && !grabbing { return false }                          // ⌘ stays with the Mac unless grabbing
        guard var k = KeyMap.keysym(e) else { return false }
        // Option is Super: the Option key itself is sent as Super in flags(); its combinations must not turn into the
        // Option-layer glyph (Option+s = ß), so use the plain key
        if keyboard == .optionSuper && e.modifierFlags.contains(.option), let plain = e.charactersIgnoringModifiers?.unicodeScalars.first, plain.value >= 0x20 {
            k = plain.value < 0x100 ? plain.value : 0x01000000 + plain.value
        }
        if e.type == .keyDown && !e.isARepeat { lastKeyAt = DispatchTime.now().uptimeNanoseconds }
        conn.send(key: k, down: e.type == .keyDown)
        return true
    }
    static let trace = ProcessInfo.processInfo.environment["MYLINUX_TRACE"] != nil
    override func keyDown(with e: NSEvent) {
        if VncView.trace { FileHandle.standardError.write("vnc keyDown code=\(e.keyCode) chars=\(e.characters ?? "") keysym=\(KeyMap.keysym(e).map { String($0, radix: 16) } ?? "nil") firstResponder=\(window?.firstResponder === self)\n".data(using: .utf8)!) }
        if !handle(e) { super.keyDown(with: e) }
    }
    override func keyUp(with e: NSEvent) { if !handle(e) { super.keyUp(with: e) } }
    override func flagsChanged(with e: NSEvent) { flags(e) }
    private func flags(_ e: NSEvent) {
        let f = e.modifierFlags
        for (flag, sym) in KeyMap.modifierKeysyms where f.contains(flag) != lastFlags.contains(flag) {
            var s = sym
            if flag == .option && keyboard == .optionSuper { s = KeyMap.superL }
            if flag == .option && keyboard != .optionSuper { s = KeyMap.altL }
            if flag == .command { if !grabbing { continue }; s = keyboard == .optionSuper ? KeyMap.altL : KeyMap.superL }
            conn.send(key: s, down: f.contains(flag))
        }
        lastFlags = f
    }
    override func resignFirstResponder() -> Bool {
        // keys held while focus leaves must not stay pressed on the remote
        for (flag, sym) in KeyMap.modifierKeysyms where lastFlags.contains(flag) { conn.send(key: flag == .option && keyboard == .optionSuper ? KeyMap.superL : sym, down: false) }
        lastFlags = []; mask = 0
        return super.resignFirstResponder()
    }

    // ---- the full grab ----
    func setGrab(_ on: Bool, keep: [String]) {
        if !on { KeyboardGrab.shared.stop(); grabbing = false; onGrabChanged?(); return }
        guard let w = window else { return }
        KeyboardGrab.shared.onRelease = { [weak self] in self?.grabbing = false; self?.onGrabChanged?() }
        grabbing = KeyboardGrab.shared.start(window: w, keep: keep) { [weak self] e in self?.handle(e) }
        onGrabChanged?()
    }
}
