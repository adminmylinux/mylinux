#include "secrets.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QRegularExpression>
#include <QDebug>

Secrets::Secrets(QObject *parent) : QObject(parent), m_path("/root/.config/mylinux/secrets.env") { load(); }

bool Secrets::validKey(const QString &key)
{
    static const QRegularExpression re(QStringLiteral("^[A-Z][A-Z0-9_]{2,63}$"));
    return re.match(key).hasMatch();
}

bool Secrets::validValue(const QString &value)
{
    if (value.size() > 4096) return false;
    for (const QChar c : value) if (c == QChar('\n') || c == QChar('\r') || c == QChar('\0')) return false;
    return true;
}

// Reads KEY=value lines; older files wrote KEY='value' with '\'' for a quote and are unwrapped.
// Lines with invalid names are ignored (and dropped on the next save).
void Secrets::load()
{
    m_values.clear();
    QFile f(m_path);
    if (!f.open(QIODevice::ReadOnly)) return;
    for (QByteArray line : f.readAll().split('\n')) {
        if (line.endsWith('\r')) line.chop(1);
        if (line.isEmpty() || line.startsWith('#')) continue;
        const int eq = line.indexOf('='); if (eq <= 0) continue;
        const QString k = QString::fromUtf8(line.left(eq));
        QString v = QString::fromUtf8(line.mid(eq + 1));
        if (v.size() >= 2 && v.startsWith('\'') && v.endsWith('\'')) v = v.mid(1, v.size() - 2).replace("'\\''", "'");
        if (validKey(k) && validValue(v)) m_values[k] = v;
    }
}

bool Secrets::save(QString *reason) const
{
    if (!QDir().mkpath(QFileInfo(m_path).path())) { *reason = "cannot create " + QFileInfo(m_path).path(); return false; }
    QSaveFile f(m_path);
    if (!f.open(QIODevice::WriteOnly)) { *reason = "cannot write " + m_path + ": " + f.errorString(); return false; }
    QByteArray out = "# myLinux secrets (Settings panel). One KEY=value per line; read as data by apps-run and the shell profile.\n";
    for (auto it = m_values.begin(); it != m_values.end(); ++it) {
        if (it.value().isEmpty()) continue;
        out += it.key().toUtf8() + "=" + it.value().toUtf8() + "\n";
    }
    if (f.write(out) != out.size()) { *reason = "short write to " + m_path + ": " + f.errorString(); f.cancelWriting(); return false; }
    f.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
    if (!f.commit()) { *reason = "could not replace " + m_path + ": " + f.errorString(); return false; }
    return true;
}

void Secrets::setError(const QString &e)
{
    if (m_error == e) return;
    m_error = e; emit errorChanged();
}

bool Secrets::set(const QString &key, const QString &value)
{
    if (!validKey(key)) { setError("invalid name '" + key + "' (A-Z, digits, _; 3-64 characters)"); emit saveFailed(m_error); return false; }
    if (!validValue(value)) { setError("value for " + key + " must be one line of at most 4096 characters"); emit saveFailed(m_error); return false; }
    if (m_values.value(key) == value) { setError(QString()); return true; }
    const QMap<QString, QString> before = m_values;
    if (value.isEmpty()) m_values.remove(key); else m_values[key] = value;
    QString reason;
    if (!save(&reason)) {
        m_values = before;              // memory keeps matching the file on disk
        qWarning() << "secrets:" << reason;
        setError(reason); emit saveFailed(reason);
        return false;
    }
    setError(QString());
    emit changed();
    return true;
}
