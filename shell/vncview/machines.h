#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

// Saved machines (~/.config/mylinux/vnc/machines.json: name, type vnc|ssh, host, port, username, quality, keyFile)
// and their passwords, which live in the secrets store (~/.config/mylinux/secrets.env) as VNC_<NAME>_PASSWORD or
// SSH_<NAME>_PASSWORD.
class Machines : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantList list READ list NOTIFY changed)
public:
    explicit Machines(QObject *parent = nullptr);
    QVariantList list() const { return m_list; }
    // entry: name, type, host, port, username, quality (vnc), keyFile (ssh); an empty password keeps the saved one
    Q_INVOKABLE void save(const QVariantMap &entry, const QString &password);
    Q_INVOKABLE void remove(const QString &name);
    Q_INVOKABLE QString password(const QString &name) const;
    Q_INVOKABLE QVariantMap get(const QString &name) const;
    // the tabs open right now (~/.config/mylinux/vnc/session.json): written on every change, removed when the last
    // tab closes or the window is closed on purpose, so a machine restart or a shell restart brings them back
    Q_INVOKABLE QVariantList session() const;
    Q_INVOKABLE void saveSession(const QVariantList &tabs);
    static QString secretKey(const QString &name, const QString &type = "vnc");
signals:
    void changed();
private:
    void load(); bool store();
    QString m_path, m_secrets, m_sessionPath;
    QVariantList m_list;
};
