#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QMap>

// API keys and other secrets, kept in the home directory (apps disk, mode 0600) as KEY='value' lines:
// /root/.config/mylinux/secrets.env. Terminals and apps get them as environment variables (qt.sh's
// ENV hook for the base shell, apps-run for the Debian chroot).
class Secrets : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString path READ path CONSTANT)
public:
    explicit Secrets(QObject *parent = nullptr);
    QString path() const { return m_path; }
    Q_INVOKABLE QString get(const QString &key) const { return m_values.value(key); }
    Q_INVOKABLE bool has(const QString &key) const { return !m_values.value(key).isEmpty(); }
    Q_INVOKABLE void set(const QString &key, const QString &value);
signals:
    void changed();
private:
    void load();
    bool save() const;
    QString m_path;
    QMap<QString, QString> m_values;
};
