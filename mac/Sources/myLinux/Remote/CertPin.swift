import Foundation
import Network
import Security

/// Trust on first use for VeNCrypt X509 servers, as in the myLinux viewer: the server's certificate is fetched once
/// over our own VeNCrypt handshake (unverified, nothing else is sent), shown to the user, and pinned as PEM under
/// ~/Library/Application Support/myLinux/vnc-certs/<host>_<port>.pem. libvncclient then verifies against that file
/// and the certificate's own name.
enum CertPin {
    struct Info: Equatable { let pem: String; let fingerprint: String; let name: String }

    static var dir: URL { Paths.support.appendingPathComponent("vnc-certs", isDirectory: true) }
    static func path(_ host: String, _ port: Int) -> URL {
        let safe = host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return dir.appendingPathComponent("\(safe)_\(port).pem")
    }
    static func pinned(_ host: String, _ port: Int) -> Info? {
        guard let pem = try? String(contentsOf: path(host, port), encoding: .utf8) else { return nil }
        return describe(pem)
    }
    static func pin(_ host: String, _ port: Int, pem: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try pem.write(to: path(host, port), atomically: true, encoding: .utf8)
    }

    static func describe(_ pem: String) -> Info? {
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return describe(cert)
    }
    static func describe(_ cert: SecCertificate) -> Info {
        let der = SecCertificateCopyData(cert) as Data
        let pem = "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: [.lineLength64Characters]) + "\n-----END CERTIFICATE-----\n"
        var hash = [UInt8](repeating: 0, count: 32)
        der.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(der.count), &hash) }
        let fp = hash.map { String(format: "%02X", $0) }.joined(separator: ":")
        var cn: CFString?
        SecCertificateCopyCommonName(cert, &cn)
        return Info(pem: pem, fingerprint: fp, name: (cn as String?) ?? "")
    }

    /// The server's certificate through the RFB + VeNCrypt X509 handshake. Completion on the main queue.
    static func fetch(host: String, port: Int, completion: @escaping (Result<Info, Error>) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
        var done = false
        func finish(_ r: Result<Info, Error>) { if !done { done = true; conn.cancel(); DispatchQueue.main.async { completion(r) } } }
        func fail(_ m: String) { finish(.failure(NSError(domain: "CertPin", code: 1, userInfo: [NSLocalizedDescriptionKey: m]))) }
        func read(_ n: Int, _ then: @escaping (Data) -> Void) {
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
                if let err { fail(err.localizedDescription); return }
                guard let data, data.count == n else { fail("the server closed the connection"); return }
                then(data)
            }
        }
        func send(_ d: Data, _ then: @escaping () -> Void) { conn.send(content: d, completion: .contentProcessed { e in if let e { fail(e.localizedDescription) } else { then() } }) }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                read(12) { v in
                    guard v.starts(with: Array("RFB ".utf8)) else { fail("not a VNC server"); return }
                    send(Data("RFB 003.008\n".utf8)) {
                        read(1) { n in
                            let count = Int(n[0]); if count == 0 { fail("the server refused the connection"); return }
                            read(count) { types in
                                guard types.contains(19) else { fail("the server does not offer VeNCrypt"); return }
                                send(Data([19])) { read(2) { _ in send(Data([0, 2])) { read(1) { ack in
                                    guard ack[0] == 0 else { fail("VeNCrypt 0.2 refused"); return }
                                    read(1) { k in read(4 * Int(k[0])) { subs in
                                        var chosen: UInt32 = 0
                                        for i in 0..<Int(k[0]) { let t = subs.subdata(in: 4*i..<4*i+4).reduce(0) { UInt32($0) << 8 | UInt32($1) }; if (260...263).contains(t) && chosen == 0 { chosen = t } }
                                        guard chosen != 0 else { fail("the server offers no certificate-based VeNCrypt type"); return }
                                        send(Data([UInt8(chosen >> 24), UInt8(chosen >> 16 & 0xff), UInt8(chosen >> 8 & 0xff), UInt8(chosen & 0xff)])) {
                                            read(1) { ok in
                                                guard ok[0] == 1 else { fail("the server refused the VeNCrypt type"); return }
                                                startTLS()
                                            }
                                        }
                                    } }
                                } } } }
                            }
                        }
                    }
                }
            case .failed(let e): fail(e.localizedDescription)
            case .waiting(let e): fail(e.localizedDescription)
            default: break
            }
        }
        func startTLS() {
            // a second connection would restart the handshake; instead run TLS on this socket's file descriptor
            // through Network's TLS options is not possible, so use a small SecureTransport-free path: openssl-like
            // handshake via NWProtocolTLS on a new connection is not equivalent. We therefore hand the raw socket to
            // a TLS session that only completes the handshake and reports the peer certificate.
            TLSPeek.peek(connection: conn, host: host) { r in
                switch r { case .success(let cert): finish(.success(describe(cert))); case .failure(let e): fail(e.localizedDescription) }
            }
        }
        conn.start(queue: DispatchQueue(label: "certpin"))
    }
}

import CommonCrypto
