#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>
#include <QTimer>
#include <QProcess>

// Tailscale node status for the menu bar: runs `tailscale status --json` (the local daemon's API, no
// cloud access) and exposes our own state plus every peer with online flag, IP and OS.
class Tailscale : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool available READ available CONSTANT)
    Q_PROPERTY(QString state READ state NOTIFY changed)          // Running, NeedsLogin, Stopped, NoState, Starting, "" (daemon not reachable)
    Q_PROPERTY(bool connected READ connected NOTIFY changed)
    Q_PROPERTY(QString selfName READ selfName NOTIFY changed)
    Q_PROPERTY(QString selfIp READ selfIp NOTIFY changed)
    Q_PROPERTY(QString tailnet READ tailnet NOTIFY changed)
    Q_PROPERTY(QVariantList peers READ peers NOTIFY changed)
    Q_PROPERTY(int onlineCount READ onlineCount NOTIFY changed)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)   // panel open: poll faster
public:
    explicit Tailscale(QObject *parent = nullptr);
    bool available() const;
    QString state() const { return m_state; }
    bool connected() const { return m_state == "Running"; }
    QString selfName() const { return m_selfName; }
    QString selfIp() const { return m_selfIp; }
    QString tailnet() const { return m_tailnet; }
    QVariantList peers() const { return m_peers; }
    int onlineCount() const { return m_online; }
    bool active() const { return m_active; }
    void setActive(bool a);
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void connectNow();      // tailscale-login window (opens the login page)
    Q_INVOKABLE void disconnect();      // tailscale down
signals:
    void changed();
    void activeChanged();
private:
    void parse(const QByteArray &json);
    QTimer m_timer;
    QProcess *m_proc = nullptr;
    bool m_active = false;
    QString m_state, m_selfName, m_selfIp, m_tailnet;
    QVariantList m_peers;
    int m_online = 0;
};
