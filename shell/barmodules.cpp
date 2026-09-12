#include "barmodules.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QQmlEngine>
#include <QQmlContext>
#include <QRegularExpression>
#include <QUrl>
#include <QDebug>

static const char *kUserDir = "/root/.config/mylinux/bar/modules";
static const char *kSharedDir = "/usr/share/mylinux/bar/modules";
static const char *kExamplesDir = "/usr/share/mylinux/bar/examples";

BarModules::BarModules(QObject *parent) : QObject(parent)
{
    m_debounce.setSingleShot(true); m_debounce.setInterval(300);
    connect(&m_debounce, &QTimer::timeout, this, &BarModules::rescan);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &) { m_debounce.start(); });
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &) { m_debounce.start(); });
    // the directories may not exist yet (created later by the user, or the apps disk bound after start): a cheap
    // poll of file names and mtimes catches that; the watcher gives instant reloads once they exist
    m_poll.setInterval(3000); connect(&m_poll, &QTimer::timeout, this, &BarModules::rescan); m_poll.start();
    QTimer::singleShot(1500, this, &BarModules::rescan);      // after the apps disk is bound
}

QString BarModules::signature() const
{
    QString sig;
    for (const QString &dir : dirs()) {
        QDir d(dir); if (!d.exists()) continue;
        for (const QFileInfo &fi : d.entryInfoList({"*.json", "*.qml"}, QDir::Files, QDir::Name))
            sig += fi.filePath() + ":" + QString::number(fi.lastModified().toMSecsSinceEpoch()) + ":" + QString::number(fi.size()) + ";";
    }
    return sig;
}

QString BarModules::userDir() const { return QString::fromLatin1(kUserDir); }
QStringList BarModules::dirs() const { return { QString::fromLatin1(kSharedDir), QString::fromLatin1(kUserDir) }; }

QVariantMap BarModules::parseDescriptor(const QJsonObject &o, const QString &dir)
{
    QVariantMap d;
    const QString id = o["id"].toString().trimmed();
    static const QRegularExpression okId("^[A-Za-z0-9_.-]{1,40}$");
    if (!okId.match(id).hasMatch()) { d["error"] = "bad id"; return d; }
    d["id"] = id;
    d["type"] = o["type"].toString() == "qml" ? "qml" : "command";
    d["exec"] = o["exec"].toString();
    d["onClick"] = o.contains("on-click") ? o["on-click"].toString() : o["onClick"].toString();
    d["interval"] = qBound(1, o["interval"].toInt(30), 3600);
    d["tooltip"] = o["tooltip"].toString();
    d["label"] = o["label"].toString();
    d["enabled"] = !o.contains("enabled") || o["enabled"].toBool(true);
    d["dir"] = dir;
    d["qml"] = d["type"] == "qml" ? QUrl::fromLocalFile(dir + "/" + id + ".qml").toString() : QString();
    d["text"] = QString(); d["color"] = QString(); d["error"] = QString();
    if (d["type"] == "qml" && !QFile::exists(dir + "/" + id + ".qml")) d["error"] = id + ".qml missing";
    if (d["type"] == "command" && d["exec"].toString().isEmpty()) d["error"] = "no exec";
    return d;
}

QVariantMap BarModules::parseOutput(const QByteArray &out)
{
    QVariantMap r;
    const QByteArray t = out.trimmed();
    if (t.startsWith('{')) {
        const QJsonObject o = QJsonDocument::fromJson(t).object();
        r["text"] = o["text"].toString(); r["tooltip"] = o["tooltip"].toString(); r["color"] = o["color"].toString(); r["class"] = o["class"].toString();
        return r;
    }
    const QList<QByteArray> lines = t.split('\n');
    r["text"] = QString::fromUtf8(lines.value(0)).left(80);
    if (lines.size() > 1) r["tooltip"] = QString::fromUtf8(lines.value(1));
    return r;
}

void BarModules::rescan()
{
    const QString sig = signature();
    if (sig == m_sig) return;                                    // nothing changed: no reload, no cache clearing
    m_sig = sig;
    // watch the directories (added when they appear)
    for (const QString &d : dirs()) if (QDir(d).exists() && !m_watcher.directories().contains(d)) m_watcher.addPath(d);
    QHash<QString, Mod> fresh; QStringList order;
    for (const QString &dir : dirs()) {
        QDir d(dir); if (!d.exists()) continue;
        for (const QString &f : d.entryList({"*.json"}, QDir::Files, QDir::Name)) {
            QFile jf(dir + "/" + f); if (!jf.open(QIODevice::ReadOnly)) continue;
            QJsonParseError pe; const QJsonObject o = QJsonDocument::fromJson(jf.readAll(), &pe).object();
            QVariantMap desc = pe.error == QJsonParseError::NoError ? parseDescriptor(o, dir) : QVariantMap{{"id", f.chopped(5)}, {"error", "invalid JSON: " + pe.errorString()}, {"type", "command"}};
            if (!desc.value("enabled", true).toBool()) continue;
            const QString id = desc["id"].toString(); if (id.isEmpty()) continue;
            if (fresh.contains(id)) order.removeAll(id);                    // the user directory overrides a shipped module
            Mod m; m.desc = desc;
            if (m_mods.contains(id)) { m.proc = m_mods[id].proc; m.timer = m_mods[id].timer; m.desc["text"] = m_mods[id].desc["text"]; m.desc["color"] = m_mods[id].desc["color"]; if (!m_mods[id].desc["tooltipOut"].toString().isEmpty()) m.desc["tooltipOut"] = m_mods[id].desc["tooltipOut"]; }
            fresh[id] = m; order << id;
            const QString qmlPath = dir + "/" + id + ".qml", jsonPath = dir + "/" + f;
            for (const QString &p : {qmlPath, jsonPath}) if (QFile::exists(p) && !m_watcher.files().contains(p)) m_watcher.addPath(p);
        }
    }
    // modules that disappeared: stop their timers/processes
    for (auto it = m_mods.begin(); it != m_mods.end(); ++it) {
        if (fresh.contains(it.key())) continue;
        if (it->timer) it->timer->deleteLater();
        if (it->proc) { it->proc->kill(); it->proc->deleteLater(); }
    }
    m_mods = fresh; m_order = order;
    // reloaded QML must not come from the component cache
    if (QQmlEngine *e = qmlEngine(this)) e->clearComponentCache();
    ++m_revision;
    for (const QString &id : m_order) {
        Mod &m = m_mods[id];
        if (m.desc["type"] != "command" || !m.desc["error"].toString().isEmpty()) continue;
        if (!m.timer) {
            m.timer = new QTimer(this);
            connect(m.timer, &QTimer::timeout, this, [this, id] { startCommand(id); });
        }
        m.timer->start(m.desc["interval"].toInt() * 1000);
        if (m.desc["text"].toString().isEmpty()) startCommand(id);
    }
    publish();
}

void BarModules::publish()
{
    QVariantList l;
    for (const QString &id : m_order) {
        QVariantMap d = m_mods[id].desc;
        if (d["tooltip"].toString().isEmpty()) d["tooltip"] = d["tooltipOut"];
        l << d;
    }
    m_list = l; emit changed();
}

// Command modules run on the apps disk when it is there (Debian tools, the user's scripts), else in the base system.
static QStringList shellFor(const QString &cmd)
{
    if (QFileInfo("/mnt/apps/usr/bin/env").exists()) return {"/usr/bin/apps-run", "sh", "-c", cmd};
    return {"/bin/sh", "-c", cmd};
}

void BarModules::startCommand(const QString &id)
{
    if (!m_mods.contains(id)) return;
    Mod &m = m_mods[id];
    if (m.proc) return;                                  // still running: skip this tick (no pile-up)
    const QStringList argv = shellFor(m.desc["exec"].toString());
    auto *p = new QProcess(this);
    m.proc = p;
    p->setProgram(argv.first()); p->setArguments(argv.mid(1));
    p->setProcessChannelMode(QProcess::SeparateChannels);
    auto *watchdog = new QTimer(p); watchdog->setSingleShot(true); watchdog->setInterval(10000);
    connect(watchdog, &QTimer::timeout, p, [p] { p->kill(); });
    connect(p, &QProcess::finished, this, [this, id, p](int code, QProcess::ExitStatus st) {
        if (m_mods.contains(id)) {
            Mod &m = m_mods[id];
            if (st == QProcess::NormalExit && code == 0) {
                const QVariantMap r = parseOutput(p->readAllStandardOutput());
                m.desc["text"] = r["text"]; m.desc["color"] = r["color"]; m.desc["tooltipOut"] = r["tooltip"]; m.desc["error"] = QString();
            } else {
                m.desc["error"] = QString("exit %1").arg(st == QProcess::NormalExit ? code : -1);
                const QString err = QString::fromUtf8(p->readAllStandardError()).trimmed();
                if (!err.isEmpty()) m.desc["tooltipOut"] = err.left(200);
            }
            m.proc = nullptr;
        }
        p->deleteLater();
        publish();
    });
    connect(p, &QProcess::errorOccurred, this, [this, id, p](QProcess::ProcessError) {
        if (m_mods.contains(id)) { m_mods[id].desc["error"] = "cannot run: " + p->errorString(); m_mods[id].proc = nullptr; }
        p->deleteLater(); publish();
    });
    watchdog->start();
    p->start();
}

void BarModules::run(const QString &id) { startCommand(id); }

void BarModules::click(const QString &id)
{
    if (!m_mods.contains(id)) return;
    const QString cmd = m_mods[id].desc["onClick"].toString();
    if (cmd.isEmpty()) { startCommand(id); return; }
    const QStringList argv = shellFor(cmd);
    QProcess::startDetached(argv.first(), argv.mid(1));
    QTimer::singleShot(1500, this, [this, id] { startCommand(id); });
}

bool BarModules::installExamples()
{
    QDir src(kExamplesDir); if (!src.exists()) return false;
    if (!QDir().mkpath(kUserDir)) return false;
    bool ok = true;
    for (const QString &f : src.entryList(QDir::Files)) {
        const QString to = QString::fromLatin1(kUserDir) + "/" + f;
        if (QFile::exists(to)) continue;                 // never overwrite the user's own version
        ok = QFile::copy(src.filePath(f), to) && ok;
        QFile::setPermissions(to, QFile::permissions(to) | QFile::ReadOwner | QFile::WriteOwner);
    }
    rescan();
    return ok;
}
