#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QVariant>

// Persistent shell settings. The rootfs lives in RAM, so the file goes to the 9p share when it is
// mounted (/mnt/share/mylinux.ini) and falls back to /tmp otherwise.
class Settings : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString path READ path CONSTANT)
public:
    explicit Settings(QObject *parent = nullptr);
    QString path() const { return m_path; }
    Q_INVOKABLE QVariant value(const QString &key, const QVariant &def = {}) const;
    Q_INVOKABLE void set(const QString &key, const QVariant &value);
private:
    QString m_path;
    QSettings *m_s = nullptr;
};
