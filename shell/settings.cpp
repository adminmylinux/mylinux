#include "settings.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>

// The share is "mounted" when /proc/mounts lists it (a bare, writable /mnt/share directory in the RAM root
// would otherwise pass an isWritable() test and silently lose every setting at shutdown).
static bool shareMounted()
{
    QFile m("/proc/mounts");
    if (!m.open(QIODevice::ReadOnly)) return QFileInfo("/mnt/share").isDir();   // not Linux (dev host): best effort
    for (const QByteArray &line : m.readAll().split('\n')) {
        const QList<QByteArray> f = line.split(' ');
        if (f.size() > 1 && f[1] == "/mnt/share") return true;
    }
    return false;
}

Settings::Settings(QObject *parent) : QObject(parent)
{
    const bool mounted = shareMounted();
    QFileInfo share("/mnt/share");
    if (mounted && share.isDir() && share.isWritable()) { m_path = QStringLiteral("/mnt/share/mylinux.ini"); m_location = QStringLiteral("share"); }
    else { m_path = QStringLiteral("/tmp/mylinux.ini"); m_location = QStringLiteral("tmp"); }
    m_s = new QSettings(m_path, QSettings::IniFormat, this);
    if (m_s->status() != QSettings::NoError) m_error = "settings file " + m_path + " could not be read";
}
QVariant Settings::value(const QString &key, const QVariant &def) const { return m_s->value(key, def); }
void Settings::set(const QString &key, const QVariant &value)
{
    m_s->setValue(key, value); m_s->sync();
    QString e;
    switch (m_s->status()) {
    case QSettings::NoError: break;
    case QSettings::AccessError: e = "cannot write " + m_path; break;
    case QSettings::FormatError: e = "settings file " + m_path + " is malformed"; break;
    }
    if (e != m_error) { m_error = e; emit statusChanged(); }
}
