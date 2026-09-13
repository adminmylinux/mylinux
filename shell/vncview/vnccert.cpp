#include "vnccert.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QRegularExpression>
#include <QSslCertificate>
#include <QSslSocket>
#include <QtEndian>

namespace VncCert {

QString pinPath(const QString &host, int port)
{
    QString h = host.trimmed(); h.replace(QRegularExpression("[^A-Za-z0-9._-]"), "_");
    return qEnvironmentVariable("HOME", "/root") + "/.config/mylinux/vnc/certs/" + h + "_" + QString::number(port) + ".pem";
}

QByteArray pinned(const QString &host, int port)
{
    QFile f(pinPath(host, port));
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

bool pin(const QString &host, int port, const QByteArray &pem)
{
    const QString path = pinPath(host, port);
    QDir().mkpath(QFileInfo(path).path());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    f.write(pem);
    return f.commit();
}

Probe describe(const QByteArray &pem)
{
    Probe p;
    const QList<QSslCertificate> certs = QSslCertificate::fromData(pem, QSsl::Pem);
    if (certs.isEmpty() || certs.first().isNull()) { p.error = "not a PEM certificate"; return p; }
    const QSslCertificate &c = certs.first();
    p.ok = true; p.pem = c.toPem();
    QStringList hex; for (const char b : c.digest(QCryptographicHash::Sha256)) hex << QString("%1").arg(quint8(b), 2, 16, QChar('0')).toUpper();
    p.fingerprint = hex.join(':');
    const QStringList dns = c.subjectAlternativeNames().values(QSsl::DnsEntry);
    const QStringList cn = c.subjectInfo(QSslCertificate::CommonName);
    p.name = !dns.isEmpty() ? dns.first() : !cn.isEmpty() ? cn.first() : QString();
    return p;
}

static bool readExact(QSslSocket &s, qsizetype n, QByteArray &out, int timeoutMs)
{
    while (s.bytesAvailable() < n) if (!s.waitForReadyRead(timeoutMs)) return false;
    out = s.read(n);
    return out.size() == n;
}

Probe fetch(const QString &host, int port, int timeoutMs)
{
    Probe p;
    QSslSocket s;
    auto fail = [&](const QString &e) { p.error = e; return p; };
    s.connectToHost(host, quint16(port));
    if (!s.waitForConnected(timeoutMs)) return fail("cannot connect: " + s.errorString());
    QByteArray b;
    if (!readExact(s, 12, b, timeoutMs) || !b.startsWith("RFB ")) return fail("not a VNC server");
    s.write("RFB 003.008\n");
    if (!readExact(s, 1, b, timeoutMs)) return fail("no security types");
    const int n = quint8(b[0]);
    if (n == 0) return fail("the server refused the connection");
    if (!readExact(s, n, b, timeoutMs)) return fail("no security types");
    if (!b.contains(char(19))) return fail("the server does not offer VeNCrypt");
    s.write(QByteArray(1, char(19)));
    if (!readExact(s, 2, b, timeoutMs)) return fail("no VeNCrypt version");
    s.write(QByteArray("\x00\x02", 2));
    if (!readExact(s, 1, b, timeoutMs) || b[0] != 0) return fail("VeNCrypt 0.2 refused");
    if (!readExact(s, 1, b, timeoutMs)) return fail("no VeNCrypt subtypes");
    const int k = quint8(b[0]);
    if (!readExact(s, 4 * k, b, timeoutMs)) return fail("no VeNCrypt subtypes");
    quint32 chosen = 0;
    for (int i = 0; i < k && !chosen; ++i) {
        const quint32 t = qFromBigEndian<quint32>(b.constData() + 4 * i);
        if (t >= 260 && t <= 263) chosen = t;          // X509None, X509Vnc, X509Plain, X509SASL
    }
    if (!chosen) return fail("the server offers no certificate-based VeNCrypt type");
    char sel[4]; qToBigEndian(chosen, sel);
    s.write(sel, 4);
    if (!readExact(s, 1, b, timeoutMs) || b[0] != 1) return fail("the server refused the VeNCrypt type");
    s.setPeerVerifyMode(QSslSocket::VerifyNone);      // only reading the certificate; nothing is sent over this connection
    s.startClientEncryption();
    if (!s.waitForEncrypted(timeoutMs)) return fail("TLS handshake failed: " + s.errorString());
    const QSslCertificate c = s.peerCertificate();
    s.abort();
    if (c.isNull()) return fail("the server sent no certificate");
    return describe(c.toPem());
}

}
