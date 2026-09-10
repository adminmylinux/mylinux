#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QSettings>
#include <QVariant>

// Persistent shell settings. The rootfs lives in RAM, so the file goes to the 9p share when it is
// mounted (/mnt/share/mylinux.ini) and falls back to /tmp otherwise; `location` says which ("share" or
// "tmp": nothing survives a reboot) and `lastError` carries a failed write.
class Settings : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString path READ path CONSTANT)
    Q_PROPERTY(QString location READ location CONSTANT)
    Q_PROPERTY(QString lastError READ lastError NOTIFY statusChanged)
public:
    explicit Settings(QObject *parent = nullptr);
    QString path() const { return m_path; }
    QString location() const { return m_location; }
    QString lastError() const { return m_error; }
    Q_INVOKABLE QVariant value(const QString &key, const QVariant &def = {}) const;
    Q_INVOKABLE void set(const QString &key, const QVariant &value);
signals:
    void statusChanged();
private:
    QString m_path, m_location, m_error;
    QSettings *m_s = nullptr;
};
