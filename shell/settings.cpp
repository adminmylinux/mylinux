#include "settings.h"
#include <QDir>
#include <QFileInfo>

Settings::Settings(QObject *parent) : QObject(parent)
{
    QFileInfo share("/mnt/share");
    m_path = (share.isDir() && share.isWritable()) ? QStringLiteral("/mnt/share/mylinux.ini")
                                                   : QStringLiteral("/tmp/mylinux.ini");
    m_s = new QSettings(m_path, QSettings::IniFormat, this);
}
QVariant Settings::value(const QString &key, const QVariant &def) const { return m_s->value(key, def); }
void Settings::set(const QString &key, const QVariant &value) { m_s->setValue(key, value); m_s->sync(); }
