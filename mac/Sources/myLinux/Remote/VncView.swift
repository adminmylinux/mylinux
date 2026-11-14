import AppKit
import QuartzCore

/// The picture of a VNC connection and its input: an IOSurface-backed layer, zoom that pans when the pointer is pushed
/// against an edge or with a ⌘⇧-drag, mouse, wheel with momentum, and keys according to the profile's keyboard mode.
final class VncView: NSView {
    let conn: VncConnection
    var keyboard: RemoteProfile.Keyboard { didSet { if keyboard != .all { KeyboardGrab.shared.stop(); grabbing = false }; onGrabChanged?() } }
    private(set) var grabbing = false
    var onGrabChanged: (() -> Void)?
    private let picture = CALayer()
    /// shows only the chosen screen: the picture sits in it, moved so that screen fills it
    private let clip = CALayer()
    private var mask: Int32 = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    // zoom: 1 = fit; larger magnifies, around the pointer (or the remote cursor), and pans at the view's edges
    var zoom: CGFloat = 1 {
        didSet { zoom = max(0.25, min(8, zoom)); keepAnchor(oldZoom: oldValue); relayout(); if zoom <= 1 { stopEdgePan() }; onZoomChanged?() }
    }
    var onZoomChanged: (() -> Void)?
    private var pan = CGPoint(x: 0.5, y: 0.5)
    /// the pointer in this view (nil: outside it), and the remote pixel it was last sent to
    private var inside: NSPoint?
    private var lastRemote: CGPoint?
    private var edgeTimer: Timer?
    /// a ⌘⇧-drag that moves the zoomed picture: where the pointer was (nil: no such drag)
    private var dragPan: NSPoint?
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
        clip.masksToBounds = true
        clip.addSublayer(picture); layer!.addSublayer(clip)
        conn.onResize = { [weak self] w, h in
            guard let self else { return }
            self.picture.contents = self.conn.surface
            if let c = self.crop, !CGRect(x: 0, y: 0, width: w, height: h).contains(c) { self.crop = nil }
            self.relayout()
        }
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
    /// One screen of the remote's (pixels from the picture's top left), shown alone; nil: the whole picture.
    var crop: CGRect? {
        didSet { guard crop != oldValue else { return }; pan = CGPoint(x: 0.5, y: 0.5); lastRemote = nil; if zoom != 1 { zoom = 1 } else { relayout(); onZoomChanged?() } }
    }
    /// what is shown of the picture: the chosen screen, or all of it
    var area: CGRect { crop ?? CGRect(x: 0, y: 0, width: conn.width, height: conn.height) }
    /// the fitted size of the area, times zoom; centred while it fits, else the pan fraction chooses the visible part
    var target: CGRect { frame(zoom: zoom) }
    private func frame(zoom: CGFloat) -> CGRect {
        guard conn.width > 0 else { return bounds }
        let a = area
        let fit = min(bounds.width / a.width, bounds.height / a.height)
        let w = a.width * fit * zoom, h = a.height * fit * zoom
        let x = w <= bounds.width ? (bounds.width - w) / 2 : -(w - bounds.width) * pan.x
        let y = h <= bounds.height ? (bounds.height - h) / 2 : -(h - bounds.height) * (1 - pan.y)   // flipped y
        return CGRect(x: x, y: y, width: w, height: h)
    }
    /// Mac points per remote pixel
    var displayScale: CGFloat { conn.width > 0 ? target.width / area.width : 1 }
    /// one remote pixel per Mac pixel
    func zoomToPixels() {
        guard conn.width > 0, bounds.width > 0 else { return }
        let fit = min(bounds.width / area.width, bounds.height / area.height)
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
        let t = target
        clip.frame = t
        if conn.width > 0 {
            let a = area, s = t.width / a.width                   // view points per remote pixel
            picture.frame = CGRect(x: -a.minX * s, y: -(CGFloat(conn.height) - a.maxY) * s, width: CGFloat(conn.width) * s, height: CGFloat(conn.height) * s)
        } else { picture.frame = clip.bounds }
        picture.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }
    /// The pan that puts the spot `r` of the remote screen (0…1 across, from its top left) at view point `a`, for a
    /// picture of `size` in a view of `view` (nil for an axis the picture fits in).
    static func pan(keeping r: CGPoint, at a: CGPoint, picture size: CGSize, view: CGSize) -> (x: CGFloat?, y: CGFloat?) {
        let x = size.width > view.width ? max(0, min(1, (r.x * size.width - a.x) / (size.width - view.width))) : nil
        // (flipped: pan.y 0 shows the top of the remote screen; the picture's top edge is then at the view's)
        let y = size.height > view.height ? max(0, min(1, 1 + (a.y + r.y * size.height - size.height) / (size.height - view.height))) : nil
        return (x, y)
    }
    /// A zoom keeps what was under the pointer under it; from the toolbar (the pointer is not here), the remote cursor
    /// stays where it was in the view.
    private func keepAnchor(oldZoom: CGFloat) {
        guard conn.width > 0, bounds.width > 0 else { return }
        let old = frame(zoom: oldZoom), new = frame(zoom: zoom)
        let ar = area
        let a = inside ?? lastRemote.map { NSPoint(x: old.minX + ($0.x - ar.minX + 0.5) * old.width / ar.width, y: old.maxY - ($0.y - ar.minY + 0.5) * old.height / ar.height) }
            ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let r = CGPoint(x: (a.x - old.minX) / old.width, y: (old.maxY - a.y) / old.height)
        let p = Self.pan(keeping: r, at: a, picture: new.size, view: bounds.size)
        if let x = p.x { pan.x = x }; if let y = p.y { pan.y = y }
    }

    // Zoomed in, the picture holds still under the pointer, so aiming is finer by the zoom, and pans while the pointer
    // is pushed against an edge, faster the nearer it is. (It used to follow every move of the pointer: the picture
    // slid under it, and the pointer reached no finer a spot than unzoomed.)
    static let edge: CGFloat = 48, edgeSpeed: CGFloat = 1400            // points; points a second at the very edge
    /// How fast to pan, in points a second of the picture, for the pointer at `p`; zero away from the edges.
    static func edgeVelocity(_ p: CGPoint, in view: CGSize) -> CGVector {
        guard p.x >= 0, p.y >= 0, p.x <= view.width, p.y <= view.height else { return CGVector() }
        func push(_ near: CGFloat, _ far: CGFloat) -> CGFloat { near < edge ? -(1 - near / edge) : far < edge ? 1 - far / edge : 0 }
        // x: the left edge shows more of the left; y (flipped): the bottom edge shows more of the bottom (pan.y up)
        return CGVector(dx: push(p.x, view.width - p.x) * edgeSpeed, dy: -push(p.y, view.height - p.y) * edgeSpeed)
    }
    private func stopEdgePan() { edgeTimer?.invalidate(); edgeTimer = nil }
    private func edgePan(_ p: NSPoint) {
        guard zoom > 1, Self.edgeVelocity(p, in: bounds.size) != CGVector() else { stopEdgePan(); return }
        guard edgeTimer == nil else { return }
        var last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let w = self.window else { self?.stopEdgePan(); return }
            let p = self.convert(w.mouseLocationOutsideOfEventStream, from: nil)
            let v = Self.edgeVelocity(p, in: self.bounds.size), now = CACurrentMediaTime(), dt = now - last; last = now
            guard self.zoom > 1, v != CGVector() else { self.stopEdgePan(); return }
            let f = self.target
            if f.width > self.bounds.width { self.pan.x = max(0, min(1, self.pan.x + v.dx * dt / (f.width - self.bounds.width))) }
            if f.height > self.bounds.height { self.pan.y = max(0, min(1, self.pan.y + v.dy * dt / (f.height - self.bounds.height))) }
            self.relayout()
            self.send(at: p)                                    // the remote pixel under the pointer moved with the picture
        }
        RunLoop.main.add(t, forMode: .common)
        edgeTimer = t
    }
    /// The pan after the picture is dragged by `d` (view points, y up), for a picture of `size` in a view of `view`:
    /// the picture follows the pointer, and stops at its edges.
    static func panned(_ pan: CGPoint, by d: CGVector, picture size: CGSize, view: CGSize) -> CGPoint {
        var p = pan
        if size.width > view.width { p.x = max(0, min(1, pan.x - d.dx / (size.width - view.width))) }
        if size.height > view.height { p.y = max(0, min(1, pan.y + d.dy / (size.height - view.height))) }   // flipped: up shows more of the bottom
        return p
    }
    private func send(at p: NSPoint) {
        let (x, y) = remote(p); lastRemote = CGPoint(x: x, y: y); conn.send(pointer: x, y, mask: mask)
    }
    func remote(_ p: NSPoint) -> (Int, Int) {
        let t = target, a = area
        guard conn.width > 0, t.width > 0 else { return (0, 0) }
        let x = Int(a.minX + (p.x - t.minX) * a.width / t.width), y = Int(a.minY + (t.maxY - p.y) * a.height / t.height)
        return (max(Int(a.minX), min(Int(a.maxX) - 1, x)), max(Int(a.minY), min(Int(a.maxY) - 1, y)))
    }

    // ---- mouse ----
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseExited(with e: NSEvent) { inside = nil; stopEdgePan() }
    private func pointer(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        inside = bounds.contains(p) ? p : nil
        edgePan(p); send(at: p)
    }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) {
        guard let from = dragPan else { pointer(e); return }
        let p = convert(e.locationInWindow, from: nil)
        pan = Self.panned(pan, by: CGVector(dx: p.x - from.x, dy: p.y - from.y), picture: target.size, view: bounds.size)
        dragPan = p; relayout()
    }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseDown(with e: NSEvent) {
        // no connection (failed, ended, not yet up): the click is the window's ("click to retry"), and grabs no keys
        guard conn.state == .connected else { super.mouseDown(with: e); return }
        window?.makeFirstResponder(self)
        // zoomed in, ⌘⇧-drag moves the picture; the remote gets no click
        if zoom > 1 && e.modifierFlags.contains([.command, .shift]) { stopEdgePan(); dragPan = convert(e.locationInWindow, from: nil); NSCursor.closedHand.push(); return }
        if keyboard == .all && !grabbing && KeyboardGrab.permitted { setGrab(true, keep: keep) }      // a click: every key to the remote again, as in Omarchy's window
        mask |= 1; pointer(e)
    }
    override func mouseUp(with e: NSEvent) {
        if dragPan != nil { dragPan = nil; NSCursor.pop(); return }
        mask &= ~1; pointer(e)
    }
    override func rightMouseDown(with e: NSEvent) { mask |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { mask &= ~4; pointer(e) }
    override func otherMouseDown(with e: NSEvent) { mask |= 2; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { mask &= ~2; pointer(e) }
    private var wheelRest = CGPoint.zero
    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) && e.hasPreciseScrollingDeltas { inside = convert(e.locationInWindow, from: nil); zoom *= 1 + e.scrollingDeltaY / 200; return }   // ⌘+trackpad zooms
        let (x, y) = remote(convert(e.locationInWindow, from: nil))
        // one RFB wheel click per notch; precise (trackpad) deltas accumulate to clicks of ~30 points
        var dy = e.scrollingDeltaY, dx = e.scrollingDeltaX
        if e.hasPreciseScrollingDeltas { wheelRest.y += dy; wheelRest.x += dx; dy = (wheelRest.y / 30).rounded(.towardZero); dx = (wheelRest.x / 30).rounded(.towardZero); wheelRest.y -= dy * 30; wheelRest.x -= dx * 30 }
        for _ in 0..<Int(min(8, abs(dy))) { let b: Int32 = dy > 0 ? 8 : 16; conn.send(pointer: x, y, mask: mask | b); conn.send(pointer: x, y, mask: mask) }
        for _ in 0..<Int(min(8, abs(dx))) { let b: Int32 = dx > 0 ? 32 : 64; conn.send(pointer: x, y, mask: mask | b); conn.send(pointer: x, y, mask: mask) }
    }
    override func magnify(with e: NSEvent) { inside = convert(e.locationInWindow, from: nil); zoom *= 1 + e.magnification }

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
        // the keys back with the Mac (⌥⌘G): the same combination sends every key to the remote again
        if keyboard == .all && !grabbing && KeyboardGrab.isSwitch(e) { if !e.isARepeat { setGrab(true, keep: keep) }; return }
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
        releaseHeld(); mask = 0
        return super.resignFirstResponder()
    }
    /// the modifiers the remote has down, up (the keyboard leaves it: focus goes, or ⌥⌘G gives the keys to the Mac,
    /// whose ⌘ up would not be sent)
    func releaseHeld() {
        for (flag, sym) in KeyMap.modifierKeysyms where lastFlags.contains(flag) {
            let s = flag == .option ? (keyboard == .optionSuper ? KeyMap.superL : KeyMap.altL) : flag == .command ? (keyboard == .optionSuper ? KeyMap.altL : KeyMap.superL) : sym
            conn.send(key: s, down: false)
        }
        // keys still held count as sent: letting go of them sends nothing more down (a stray Alt)
        lastFlags = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
    }

    // ---- the full grab ----
    /// the shortcuts the Mac keeps while grabbing (the profile's)
    private var keep: [String] = []
    func setGrab(_ on: Bool, keep: [String]) {
        self.keep = keep
        if !on { KeyboardGrab.shared.stop(); grabbing = false; releaseHeld(); onGrabChanged?(); return }
        guard let w = window else { return }
        KeyboardGrab.shared.onRelease = { [weak self] in self?.grabbing = false; self?.releaseHeld(); self?.onGrabChanged?() }
        grabbing = KeyboardGrab.shared.start(window: w, keep: keep) { [weak self] e in self?.handle(e) }
        onGrabChanged?()
    }
}
