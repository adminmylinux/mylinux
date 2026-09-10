#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QMap>

// API keys and other secrets, kept in the home directory (apps disk, mode 0600) as KEY=value lines:
// /root/.config/mylinux/secrets.env. The file is data: apps-run and profile.d/secrets.sh parse it
// (never source it) and export the lines only to shells, coding agents and developer tools.
// Names must match ^[A-Z][A-Z0-9_]{2,63}$; values are single lines of at most 4096 characters.
class Secrets : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString path READ path CONSTANT)
    Q_PROPERTY(QString lastError READ lastError NOTIFY errorChanged)   // "" after a successful save
public:
    explicit Secrets(QObject *parent = nullptr);
    QString path() const { return m_path; }
    QString lastError() const { return m_error; }
    Q_INVOKABLE QString get(const QString &key) const { return m_values.value(key); }
    Q_INVOKABLE bool has(const QString &key) const { return !m_values.value(key).isEmpty(); }
    // false (with lastError set and saveFailed emitted) when the name or value is invalid or the file
    // could not be written; the previous values stay in memory and on disk.
    Q_INVOKABLE bool set(const QString &key, const QString &value);
    static bool validKey(const QString &key);
    static bool validValue(const QString &value);
signals:
    void changed();
    void errorChanged();
    void saveFailed(const QString &reason);
private:
    void load();
    bool save(QString *reason) const;
    void setError(const QString &e);
    QString m_path, m_error;
    QMap<QString, QString> m_values;
};
