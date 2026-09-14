#include "machines.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QRegularExpression>
#include <QDebug>

Machines::Machines(QObject *parent) : QObject(parent)
{
    const QString home = qEnvironmentVariable("HOME", "/root");
    m_path = home + "/.config/mylinux/vnc/machines.json";
    m_secrets = home + "/.config/mylinux/secrets.env";
    load();
}

QString Machines::secretKey(const QString &name, const QString &type)
{
    QString k = name.toUpper().replace(QRegularExpression("[^A-Z0-9]+"), "_").remove(QRegularExpression("^_+|_+$"));
    if (k.isEmpty()) k = "DEFAULT";
    return (type == "ssh" ? "SSH_" : "VNC_") + k + "_PASSWORD";
}

void Machines::load()
{
    m_list.clear();
    QFile f(m_path);
    if (f.open(QIODevice::ReadOnly)) for (const QJsonValue &v : QJsonDocument::fromJson(f.readAll()).array()) {
        QVariantMap e = v.toObject().toVariantMap();
        if (e.value("type").toString() != "ssh") e["type"] = "vnc";        // entries from before SSH tabs
        m_list << e;
    }
    emit changed();
}

bool Machines::store()
{
    QDir().mkpath(QFileInfo(m_path).path());
    QSaveFile f(m_path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    QJsonArray a; for (const QVariant &v : m_list) a << QJsonObject::fromVariantMap(v.toMap());
    f.write(QJsonDocument(a).toJson(QJsonDocument::Indented));
    return f.commit();
}

QVariantMap Machines::get(const QString &name) const
{
    for (const QVariant &v : m_list) if (v.toMap()["name"] == name) return v.toMap();
    return {};
}

// secrets.env: KEY=value lines, read and rewritten as data (never sourced); the file stays 0600
static QMap<QString, QString> readSecrets(const QString &path)
{
    QMap<QString, QString> m; QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return m;
    for (QByteArray line : f.readAll().split('\n')) {
        if (line.isEmpty() || line.startsWith('#')) continue;
        const int eq = line.indexOf('='); if (eq <= 0) continue;
        QString v = QString::fromUtf8(line.mid(eq + 1));
        if (v.size() >= 2 && v.startsWith('\'') && v.endsWith('\'')) v = v.mid(1, v.size() - 2).replace("'\\''", "'");
        m[QString::fromUtf8(line.left(eq))] = v;
    }
    return m;
}
static bool writeSecrets(const QString &path, const QMap<QString, QString> &m)
{
    QDir().mkpath(QFileInfo(path).path());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) return false;
    QByteArray out = "# myLinux secrets (Settings panel, vncview). One KEY=value per line; read as data by apps-run and the shell profile.\n";
    for (auto it = m.begin(); it != m.end(); ++it) if (!it.value().isEmpty()) out += it.key().toUtf8() + "=" + it.value().toUtf8() + "\n";
    f.write(out); f.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
    return f.commit();
}

QString Machines::password(const QString &name) const { return readSecrets(m_secrets).value(secretKey(name, get(name).value("type").toString())); }

void Machines::save(const QVariantMap &entry, const QString &password)
{
    const QString n = entry["name"].toString().trimmed(); if (n.isEmpty()) return;
    const QString type = entry["type"].toString() == "ssh" ? "ssh" : "vnc";
    QVariantMap e;
    e["name"] = n; e["type"] = type; e["host"] = entry["host"].toString().trimmed();
    const int port = entry["port"].toInt(); e["port"] = port > 0 ? port : (type == "ssh" ? 22 : 5900);
    e["username"] = entry["username"].toString().trimmed();
    if (type == "vnc") { const QString q = entry["quality"].toString(); e["quality"] = q.isEmpty() ? "balanced" : q; }
    else e["keyFile"] = entry["keyFile"].toString().trimmed();
    bool replaced = false;
    for (int i = 0; i < m_list.size(); ++i) if (m_list[i].toMap()["name"] == n) { m_list[i] = e; replaced = true; }
    if (!replaced) m_list << e;
    if (!store()) qWarning() << "vncview: cannot write" << m_path;
    if (!password.isEmpty()) { QMap<QString, QString> s = readSecrets(m_secrets); s[secretKey(n, type)] = password; if (!writeSecrets(m_secrets, s)) qWarning() << "vncview: cannot write" << m_secrets; }
    emit changed();
}

void Machines::remove(const QString &name)
{
    for (int i = 0; i < m_list.size(); ++i) if (m_list[i].toMap()["name"] == name) { m_list.removeAt(i); break; }
    store();
    QMap<QString, QString> s = readSecrets(m_secrets);
    if (s.remove(secretKey(name, "vnc")) + s.remove(secretKey(name, "ssh"))) writeSecrets(m_secrets, s);
    emit changed();
}
