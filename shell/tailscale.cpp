#include "tailscale.h"
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>
#include <algorithm>

Tailscale::Tailscale(QObject *parent) : QObject(parent)
{
    connect(&m_timer, &QTimer::timeout, this, &Tailscale::refresh);
    m_timer.start(30000);
    m_watchdog.setSingleShot(true); m_watchdog.setInterval(8000);
    connect(&m_watchdog, &QTimer::timeout, this, &Tailscale::onWatchdog);

    QTimer::singleShot(3000, this, &Tailscale::refresh);
}

bool Tailscale::available() const { return QFileInfo::exists("/usr/bin/tailscale"); }

void Tailscale::setActive(bool a)
{
    if (a == m_active) return;
    m_active = a; emit activeChanged();
    m_timer.start(a ? 4000 : 30000);
    if (a) refresh();
}

// One status query at a time, with a bounded lifetime: a query that fails to start or hangs is dropped
// (watchdog) so the next refresh can run; the failure is kept in lastError.
void Tailscale::refresh()
{
    if (!available() || m_proc) return;
    m_proc = new QProcess(this);
    QProcess *p = m_proc;
    connect(p, &QProcess::finished, this, [this, p](int code, QProcess::ExitStatus st) {
        const QByteArray out = p->readAllStandardOutput();
        dropProcess();
        if (st != QProcess::NormalExit || code != 0) setError(QStringLiteral("tailscale status exited with %1").arg(code));
        else setError(QString());
        parse(out);
    });
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError) {
        const QString e = p->errorString();
        dropProcess();
        setError("tailscale status: " + e);
        parse(QByteArray());
    });
    m_watchdog.start();
    p->start("/usr/bin/tailscale", {"status", "--json", "--peers=true"});
}

void Tailscale::dropProcess()
{
    m_watchdog.stop();
    if (!m_proc) return;
    m_proc->disconnect(this);
    if (m_proc->state() != QProcess::NotRunning) m_proc->kill();
    m_proc->deleteLater(); m_proc = nullptr;
}

void Tailscale::onWatchdog()
{
    if (!m_proc) return;
    dropProcess();
    setError(QStringLiteral("tailscale status did not answer within 8 s"));
    parse(QByteArray());
}

void Tailscale::setError(const QString &e)
{
    if (m_error == e) return;
    if (!e.isEmpty()) qWarning() << "tailscale:" << e;
    m_error = e; emit changed();
}


void Tailscale::parse(const QByteArray &json)
{
    const QJsonObject o = QJsonDocument::fromJson(json).object();
    QString state = o.value("BackendState").toString();
    QString name, ip, tailnet; QVariantList peers; int online = 0;
    if (!o.isEmpty()) {
        const QJsonObject self = o.value("Self").toObject();
        name = self.value("HostName").toString();
        const QJsonArray ips = self.value("TailscaleIPs").toArray();
        if (!ips.isEmpty()) ip = ips.first().toString();
        tailnet = o.value("CurrentTailnet").toObject().value("Name").toString();
        if (tailnet.isEmpty()) tailnet = o.value("MagicDNSSuffix").toString();
        const QJsonObject ps = o.value("Peer").toObject();
        for (auto it = ps.begin(); it != ps.end(); ++it) {
            const QJsonObject p = it.value().toObject();
            QVariantMap m;
            QString dns = p.value("DNSName").toString(); if (dns.endsWith('.')) dns.chop(1);
            m["dns"] = dns;
            // the tailnet machine name (first DNS label) is what the admin console shows; HostName can be
            // "localhost" (iPhones) or the raw OS host name
            const QString label = dns.section('.', 0, 0);
            const QString host = p.value("HostName").toString();
            m["name"] = !label.isEmpty() ? label : host;
            const QJsonArray pips = p.value("TailscaleIPs").toArray();
            m["ip"] = pips.isEmpty() ? QString() : pips.first().toString();
            m["online"] = p.value("Online").toBool();
            m["os"] = p.value("OS").toString();
            m["lastSeen"] = p.value("LastSeen").toString();
            m["exitNode"] = p.value("ExitNodeOption").toBool();
            if (m["online"].toBool()) ++online;
            peers << m;
        }
        std::sort(peers.begin(), peers.end(), [](const QVariant &a, const QVariant &b) {
            const QVariantMap x = a.toMap(), y = b.toMap();
            if (x["online"].toBool() != y["online"].toBool()) return x["online"].toBool();
            return x["name"].toString().toLower() < y["name"].toString().toLower();
        });
    }
    m_state = state; m_selfName = name; m_selfIp = ip; m_tailnet = tailnet; m_peers = peers; m_online = online;
    emit changed();
}

void Tailscale::connectNow() { QProcess::startDetached("/usr/bin/tailscale-login", {}); QTimer::singleShot(2000, this, &Tailscale::refresh); }
void Tailscale::disconnect() { QProcess::startDetached("/usr/bin/tailscale", {"down"}); QTimer::singleShot(1500, this, &Tailscale::refresh); }
