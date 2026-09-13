#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

// Saved machines (~/.config/mylinux/vnc/machines.json: name, host, port, username, quality) and their
// passwords, which live in the secrets store (~/.config/mylinux/secrets.env) as VNC_<NAME>_PASSWORD.
class Machines : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantList list READ list NOTIFY changed)
public:
    explicit Machines(QObject *parent = nullptr);
    QVariantList list() const { return m_list; }
    Q_INVOKABLE void save(const QString &name, const QString &host, int port, const QString &username, const QString &quality, const QString &password);
    Q_INVOKABLE void remove(const QString &name);
    Q_INVOKABLE QString password(const QString &name) const;
    Q_INVOKABLE QVariantMap get(const QString &name) const;
    static QString secretKey(const QString &name);
signals:
    void changed();
private:
    void load(); bool store();
    QString m_path, m_secrets;
    QVariantList m_list;
};
