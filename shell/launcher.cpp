#include "launcher.h"
#include <QProcess>
#include <QProcessEnvironment>
#include <QDebug>
#include <QFile>
#include <QRegularExpression>

Launcher::Launcher(QObject *parent) : QObject(parent) {}

QString Launcher::socketName() const { return QStringLiteral("wayland-0"); }

bool Launcher::launch(const QString &program, const QStringList &args)
{
    auto *p = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // Clients are ordinary Wayland apps: no direct evdev/KMS access.
    for (const char *k : {"QT_QPA_GENERIC_PLUGINS", "QT_QPA_EGLFS_INTEGRATION", "QT_QPA_EGLFS_DISABLE_INPUT",
                          "QT_QPA_FB_DISABLE_INPUT", "QT_QPA_EGLFS_ALWAYS_SET_MODE", "QT_QPA_EGLFS_HIDECURSOR",
                          "QT_QPA_FB_HIDECURSOR", "MYSHELL_PLATFORM", "MESA_LOADER_DRIVER_OVERRIDE"})
        env.remove(QLatin1String(k));
    env.insert("QT_QPA_PLATFORM", "wayland");
    // Clients render in software into wl_shm buffers: no EGL/DRM access needed, works on any compositor path.
    env.insert("QT_QUICK_BACKEND", "software");
    env.insert("WAYLAND_DISPLAY", socketName());
    env.insert("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1"); // the shell draws the frames
    if (!env.contains("TERM")) env.insert("TERM", "foot");
    p->setProcessEnvironment(env);
    p->setProcessChannelMode(QProcess::ForwardedChannels);
    p->setProgram(program);
    p->setArguments(args);
    connect(p, &QProcess::errorOccurred, this, [this, p, program](QProcess::ProcessError) {
        qWarning() << "launch failed:" << program << p->errorString();
        emit failed(program, p->errorString());
    });
    connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), p, &QObject::deleteLater);
    p->start();
    if (!p->waitForStarted(3000)) return false;
    emit launched(program, p->processId());
    return true;
}

void Launcher::setTerminalFont(int pt)
{
    QFile f(QStringLiteral("/etc/xdg/foot/foot.ini"));
    if (!f.open(QIODevice::ReadOnly)) return;
    QString ini = QString::fromUtf8(f.readAll()); f.close();
    ini.replace(QRegularExpression(QStringLiteral("^font=.*$"), QRegularExpression::MultilineOption),
                QStringLiteral("font=DejaVu Sans Mono:size=%1").arg(pt));
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) { f.write(ini.toUtf8()); f.close(); }
}

bool Launcher::hostCommand(const QString &cmd)
{
    QFile f(QStringLiteral("/mnt/share/host-cmd"));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) { qWarning() << "host-cmd: share not writable"; return false; }
    f.write(cmd.toUtf8()); f.write("\n"); f.close();
    return true;
}

bool Launcher::fileExists(const QString &path) const { return QFile::exists(path); }
