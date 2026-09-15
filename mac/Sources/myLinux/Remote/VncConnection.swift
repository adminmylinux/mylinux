import AppKit
import IOSurface
import CVncClient

/// One VNC connection: libvncclient on its own thread, decoding into an IOSurface (or, when the surface's rows are
/// padded, into a staging buffer from which only the damaged rectangles are copied). Input events are queued to the
/// thread; state, resizes and frames are reported on the main queue.
final class VncConnection {
    enum State: Equatable { case idle, connecting, connected, untrusted(CertPin.Info, changed: Bool), failed(String), closed }

    let profile: RemoteProfile
    var password = ""
    private(set) var state = State.idle { didSet { let s = state; DispatchQueue.main.async { [self] in onState?(s) } } }   // the value set, not the one current when the main queue gets to it
    private(set) var surface: IOSurface?
    private(set) var width = 0, height = 0
    var onState: ((State) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onFrame: ((CGRect) -> Void)?
    var onServerText: ((String) -> Void)?
    // stats for the HUD
    var updates = 0, rects = 0, decodeNs: UInt64 = 0

    private var thread: Thread?
    private let lock = NSLock()
    private enum Ev { case key(UInt32, Bool), pointer(Int, Int, Int32), text(String) }
    private var queue: [Ev] = []
    private var quit = false
    private var damage = CGRect.null
    private var staging: UnsafeMutablePointer<UInt8>?
    private var direct = true
    private var pinUsed: CertPin.Info?
    private var needTrust = false
    private var lastLog = ""

    init(profile: RemoteProfile) { self.profile = profile }
    deinit { staging?.deallocate() }

    private static func selfOf(_ c: UnsafeMutablePointer<rfbClient>?) -> VncConnection {
        Unmanaged<VncConnection>.fromOpaque(rfbClientGetClientData(c, UnsafeMutableRawPointer(bitPattern: 1))).takeUnretainedValue()
    }

    func start() {
        quit = false; needTrust = false; pinUsed = nil; lastLog = ""
        thread = Thread { [self] in run() }
        thread!.name = "vnc \(profile.title)"; thread!.start()
    }
    func stop() { quit = true }
    func send(key: UInt32, down: Bool) { lock.lock(); queue.append(.key(key, down)); lock.unlock() }
    func send(pointer x: Int, _ y: Int, mask: Int32) { lock.lock(); queue.append(.pointer(x, y, mask)); lock.unlock() }
    func send(text: String) { lock.lock(); queue.append(.text(text)); lock.unlock() }

    /// pin the offered certificate (state .untrusted) and connect again
    func trust() {
        guard case .untrusted(let info, _) = state else { return }
        do { try CertPin.pin(profile.host, profile.port, pem: info.pem) } catch { state = .failed("cannot save the certificate: \(error.localizedDescription)"); return }
        start()
    }

    private func run() {
        guard let c = rfbGetClient(8, 3, 4) else { state = .failed("rfbGetClient failed"); return }
        rfbClientSetClientData(c, UnsafeMutableRawPointer(bitPattern: 1), Unmanaged.passUnretained(self).toOpaque())
        c.pointee.MallocFrameBuffer = { c in
            let s = VncConnection.selfOf(c)
            let w = Int(c!.pointee.width), h = Int(c!.pointee.height)
            guard w > 0, h > 0, let surf = IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4, .pixelFormat: UInt32(0x42475241)]) else { return 0 }
            IOSurfaceLock(surf, [], nil); memset(surf.baseAddress, 0, surf.allocationSize); IOSurfaceUnlock(surf, [], nil)
            s.surface = surf; s.width = w; s.height = h
            s.direct = surf.bytesPerRow == w * 4
            s.staging?.deallocate(); s.staging = nil
            if s.direct { c!.pointee.frameBuffer = surf.baseAddress.assumingMemoryBound(to: UInt8.self) }
            else { s.staging = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4); c!.pointee.frameBuffer = s.staging }
            c!.pointee.format.bitsPerPixel = 32; c!.pointee.format.depth = 24; c!.pointee.format.trueColour = 1; c!.pointee.format.bigEndian = 0
            c!.pointee.format.redShift = 16; c!.pointee.format.greenShift = 8; c!.pointee.format.blueShift = 0
            c!.pointee.format.redMax = 255; c!.pointee.format.greenMax = 255; c!.pointee.format.blueMax = 255
            SetFormatAndEncodings(c)
            DispatchQueue.main.async { s.onResize?(w, h) }
            return 1
        }
        c.pointee.GotFrameBufferUpdate = { c, x, y, w, h in
            let s = VncConnection.selfOf(c); s.rects += 1
            s.damage = s.damage.union(CGRect(x: Int(x), y: Int(y), width: Int(w), height: Int(h)))
        }
        c.pointee.FinishedFrameBufferUpdate = { c in
            let s = VncConnection.selfOf(c); s.updates += 1
            let d = s.damage; s.damage = .null
            guard !d.isNull else { return }
            if !s.direct, let surf = s.surface, let src = s.staging {
                let r = d.intersection(CGRect(x: 0, y: 0, width: s.width, height: s.height)).integral
                let dst = surf.baseAddress.assumingMemoryBound(to: UInt8.self), stride = surf.bytesPerRow
                for y in Int(r.minY)..<Int(r.maxY) { memcpy(dst + y * stride + Int(r.minX) * 4, src + (y * s.width + Int(r.minX)) * 4, Int(r.width) * 4) }
            }
            DispatchQueue.main.async { s.onFrame?(d) }
        }
        c.pointee.GotXCutText = { c, text, len in
            let s = VncConnection.selfOf(c)
            guard let text else { return }
            let str = String(data: Data(bytes: text, count: Int(len)), encoding: .isoLatin1) ?? ""
            DispatchQueue.main.async { s.onServerText?(str) }
        }
        c.pointee.GetPassword = { c in strdup(VncConnection.selfOf(c).password) }
        c.pointee.GetCredential = { c, type in
            let s = VncConnection.selfOf(c)
            let cred = calloc(1, MemoryLayout<rfbCredential>.size)!.assumingMemoryBound(to: rfbCredential.self)
            if type == rfbCredentialTypeUser {
                cred.pointee.userCredential.username = strdup(s.profile.username); cred.pointee.userCredential.password = strdup(s.password)
                return cred
            }
            // X509: only a pinned certificate is trusted; without one, stop and let the user decide
            guard let pin = CertPin.pinned(s.profile.host, s.profile.port) else { s.needTrust = true; free(cred); return nil }
            s.pinUsed = pin
            cred.pointee.x509Credential.x509CACertFile = strdup(CertPin.path(s.profile.host, s.profile.port).path)
            cred.pointee.x509Credential.x509CrlVerifyMode = UInt8(rfbX509CrlVerifyNone)
            if !pin.name.isEmpty { free(c!.pointee.serverHost); c!.pointee.serverHost = strdup(pin.name) }   // verify the name the certificate carries
            return cred
        }
        c.pointee.canHandleNewFBSize = 1
        c.pointee.serverHost = strdup(profile.host); c.pointee.serverPort = Int32(profile.port)
        c.pointee.appData.encodingsString = UnsafePointer(strdup("tight zrle copyrect hextile zlib raw"))
        c.pointee.appData.enableJPEG = 1
        c.pointee.appData.qualityLevel = profile.quality == "fast" ? 4 : profile.quality == "best" ? 9 : 7
        c.pointee.appData.compressLevel = profile.quality == "fast" ? 2 : profile.quality == "best" ? 6 : 3
        c.pointee.appData.useRemoteCursor = 0
        var schemes: [UInt32] = [UInt32(rfbVeNCrypt), UInt32(rfbVncAuth), UInt32(rfbNoAuth), UInt32(rfbARD), 0]
        SetClientAuthSchemes(c, &schemes, -1)
        state = .connecting
        // connect first, so the certificate can be verified against its own name later (libvncclient checks serverHost)
        if ConnectToRFBServer(c, profile.host, Int32(profile.port)) == 0 { rfbClientCleanup(c); state = .failed("cannot connect to \(profile.host):\(profile.port)"); return }
        c.pointee.listenSpecified = 1
        if rfbInitClient(c, nil, nil) == 0 {                       // frees the client on failure
            if needTrust || pinUsed != nil { probeCertificate(); return }
            state = .failed("connection failed (wrong password, or the server refused)"); return
        }
        state = .connected
        while !quit {
            let r = WaitForMessage(c, 5000)
            if r < 0 { break }
            if r > 0 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                if direct, let surf = surface { IOSurfaceLock(surf, [], nil) }
                let ok = HandleRFBServerMessage(c)
                if direct, let surf = surface { IOSurfaceUnlock(surf, [], nil) }
                decodeNs += DispatchTime.now().uptimeNanoseconds - t0
                if ok == 0 { break }
            }
            lock.lock(); let ev = queue; queue.removeAll(); lock.unlock()
            for e in ev {
                switch e {
                case .key(let k, let d): SendKeyEvent(c, k, d ? 1 : 0)
                case .pointer(let x, let y, let m): SendPointerEvent(c, Int32(x), Int32(y), m)
                case .text(let t): var bytes = Array(t.utf8CString); bytes.withUnsafeMutableBufferPointer { p in _ = SendClientCutText(c, p.baseAddress, Int32(t.utf8.count)) }
                }
            }
        }
        c.pointee.frameBuffer = nil
        rfbClientCleanup(c)
        state = quit ? .closed : .failed("connection lost")
    }

    /// after a failed X509 handshake: an unknown or changed certificate becomes a trust question
    private func probeCertificate() {
        let wanted = needTrust, pinned = pinUsed
        CertPin.fetch(host: profile.host, port: profile.port) { [self] r in
            switch r {
            case .success(let info):
                if wanted || info.fingerprint != pinned?.fingerprint { state = .untrusted(info, changed: !wanted) }
                else { state = .failed("connection failed (wrong password, or the server refused)") }
            case .failure(let e): state = .failed("cannot read the server certificate: \(e.localizedDescription)")
            }
        }
    }
}
