import Foundation
import Network
import Security

/// Completes a TLS handshake on an already-open NWConnection (the VeNCrypt handshake has happened on it) without
/// verifying anything, and returns the peer's leaf certificate. Implemented with SecureTransport-style framing over
/// Network: TLS records are exchanged through a `NWProtocolFramer`-free path by wrapping the connection in a second
/// NWConnection is not possible, so the handshake runs on `SSLContext` with custom read/write callbacks. The API is
/// deprecated but present, and it is the only Apple way to run TLS over a socket we already negotiated on.
enum TLSPeek {
    private final class IO { let conn: NWConnection; var inbox = Data(); let lock = NSLock(); let sem = DispatchSemaphore(value: 0); var closed = false
        init(_ c: NWConnection) { conn = c } }

    static func peek(connection: NWConnection, host: String, completion: @escaping (Result<SecCertificate, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let io = IO(connection)
            func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                    io.lock.lock()
                    if let data { io.inbox.append(data) }
                    if isComplete || err != nil { io.closed = true }
                    io.lock.unlock(); io.sem.signal()
                    if !(isComplete || err != nil) { pump() }
                }
            }
            pump()
            guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else { completion(.failure(err("no TLS context"))); return }
            SSLSetIOFuncs(ctx, { ref, buf, len in
                let io = Unmanaged<IO>.fromOpaque(ref).takeUnretainedValue()
                var want = len.pointee; var got = 0
                while got < want {
                    io.lock.lock()
                    let n = min(io.inbox.count, want - got)
                    if n > 0 { io.inbox.copyBytes(to: (buf + got).assumingMemoryBound(to: UInt8.self), count: n); io.inbox.removeFirst(n); got += n }
                    let closed = io.closed
                    io.lock.unlock()
                    if got == want { break }
                    if closed { len.pointee = got; return errSSLClosedGraceful }
                    if io.sem.wait(timeout: .now() + 6) == .timedOut { len.pointee = got; return errSSLWouldBlock }
                }
                len.pointee = got; want = 0; return errSecSuccess
            }, { ref, buf, len in
                let io = Unmanaged<IO>.fromOpaque(ref).takeUnretainedValue()
                let d = Data(bytes: buf, count: len.pointee); let sem = DispatchSemaphore(value: 0); var failed = false
                io.conn.send(content: d, completion: .contentProcessed { e in failed = e != nil; sem.signal() }); sem.wait()
                return failed ? errSSLClosedAbort : errSecSuccess
            })
            SSLSetConnection(ctx, Unmanaged.passUnretained(io).toOpaque())
            SSLSetPeerDomainName(ctx, host, host.utf8.count)
            SSLSetSessionOption(ctx, .breakOnServerAuth, true)         // stop after the certificate arrives: no verification here
            var status = SSLHandshake(ctx)
            var trust: SecTrust?
            if status == errSSLPeerAuthCompleted || status == errSecSuccess { SSLCopyPeerTrust(ctx, &trust) }
            else if status == errSSLWouldBlock { status = SSLHandshake(ctx); if status == errSSLPeerAuthCompleted { SSLCopyPeerTrust(ctx, &trust) } }
            SSLClose(ctx)
            if let trust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first { completion(.success(leaf)) }
            else { completion(.failure(err("TLS handshake failed (status \(status))"))) }
        }
    }
    private static func err(_ m: String) -> Error { NSError(domain: "TLSPeek", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}
