#include "secrets.h"
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QDebug>

Secrets::Secrets(QObject *parent) : QObject(parent), m_path("/root/.config/mylinux/secrets.env") { load(); }

void Secrets::load()
{
    m_values.clear();
    QFile f(m_path);
    if (!f.open(QIODevice::ReadOnly)) return;
    for (QByteArray line : f.readAll().split('\n')) {
        line = line.trimmed();
        if (line.isEmpty() || line.startsWith('#')) continue;
        const int eq = line.indexOf('='); if (eq <= 0) continue;
        QString v = QString::fromUtf8(line.mid(eq + 1));
        if (v.size() >= 2 && v.startsWith('\'') && v.endsWith('\'')) v = v.mid(1, v.size() - 2).replace("'\\''", "'");
        m_values[QString::fromUtf8(line.left(eq))] = v;
    }
}

bool Secrets::save() const
{
    QDir().mkpath(QFileInfo(m_path).path());
    QSaveFile f(m_path);
    if (!f.open(QIODevice::WriteOnly)) { qWarning() << "secrets: cannot write" << m_path; return false; }
    QByteArray out = "# myLinux secrets (Settings panel). Exported to terminals and apps as environment variables.\n";
    for (auto it = m_values.begin(); it != m_values.end(); ++it) {
        if (it.value().isEmpty()) continue;
        QString v = it.value(); v.replace("'", "'\\''");
        out += it.key().toUtf8() + "='" + v.toUtf8() + "'\n";
    }
    f.write(out);
    f.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
    return f.commit();
}

void Secrets::set(const QString &key, const QString &value)
{
    if (m_values.value(key) == value) return;
    m_values[key] = value;
    save();
    emit changed();
}
