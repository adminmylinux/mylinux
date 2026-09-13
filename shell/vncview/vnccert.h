#pragma once
#include <QByteArray>
#include <QString>

// Trust on first use for VeNCrypt X509 servers (wayvnc with TLS): libvncclient verifies the server certificate
// against a CA file and the host name, and self-signed server certificates have neither. The viewer fetches the
// certificate once over its own connection, the user compares the fingerprint and trusts it, and the PEM is pinned
// in ~/.config/mylinux/vnc/certs/<host>_<port>.pem. Later connections verify against exactly that certificate.
namespace VncCert {

struct Probe {
    bool ok = false;
    QByteArray pem;
    QString fingerprint;     // SHA-256, colon-separated hex
    QString name;            // the name verification checks (first DNS alternative name, else the common name)
    QString error;
};

QString pinPath(const QString &host, int port);
QByteArray pinned(const QString &host, int port);                   // empty when nothing is pinned
bool pin(const QString &host, int port, const QByteArray &pem);
Probe describe(const QByteArray &pem);                                // fingerprint and name of a PEM
// The server's certificate through the VeNCrypt X509 handshake, unverified (for showing to the user only).
// Blocking; call it from a worker thread.
Probe fetch(const QString &host, int port, int timeoutMs = 6000);

}
