#include "launcher.h"
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <QDir>
#include <QProcess>
#include <QProcessEnvironment>
#include <QDebug>
#include <QFile>
#include <QRegularExpression>
#include <QWaylandSeat>
#include <QWaylandKeyboard>
#include <QKeyEvent>
#include <QWaylandSurface>

Launcher::Launcher(QObject *parent) : QObject(parent) {}

QString Launcher::socketName() const { return QStringLiteral("wayland-0"); }

// Detached start: the compositor never waits on a client (no waitForStarted on the UI thread) and keeps no
// QProcess object per launch; a start failure is reported at once through failed(). The client's output goes
// to /var/log/apps.log.
bool Launcher::launch(const QString &program, const QStringList &args)
{
    QProcess proc;
    QProcess *p = &proc;
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
    p->setStandardOutputFile(QStringLiteral("/var/log/apps.log"), QIODevice::Append);
    p->setStandardErrorFile(QStringLiteral("/var/log/apps.log"), QIODevice::Append);
    p->setProgram(program);
    p->setArguments(args);
    qint64 pid = 0;
    if (!p->startDetached(&pid)) {
        qWarning() << "launch failed:" << program << p->errorString();
        emit failed(program, p->errorString());
        return false;
    }
    emit launched(program, pid);
    return true;
}


// the pty foot (pid) put its shell on: the first child process whose stdin is a /dev/pts device
static QString terminalPty(qint64 pid)
{
    const QDir proc("/proc");
    for (const QString &entry : proc.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        bool ok; entry.toLongLong(&ok); if (!ok) continue;
        QFile stat("/proc/" + entry + "/stat");
        if (!stat.open(QIODevice::ReadOnly)) continue;
        const QByteArray line = stat.readAll();
        const int paren = line.lastIndexOf(')');
        const QList<QByteArray> fields = line.mid(paren + 2).split(' ');   // state ppid ...
        if (fields.size() < 2 || fields[1].toLongLong() != pid) continue;
        const QString tty = QFile::symLinkTarget("/proc/" + entry + "/fd/0");
        if (tty.startsWith("/dev/pts/")) return tty;
    }
    return QString();
}

bool Launcher::setTerminalPalette(qint64 pid, const QVariantMap &palette)
{
    if (pid <= 1) return false;
    QFile comm(QStringLiteral("/proc/%1/comm").arg(pid));
    if (!comm.open(QIODevice::ReadOnly) || comm.readAll().trimmed() != "foot") return false;
    const QString pty = terminalPty(pid);
    if (pty.isEmpty()) return false;
    const int fd = ::open(QFile::encodeName(pty).constData(), O_WRONLY | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) return false;
    QByteArray seq;
    auto osc = [&](const QByteArray &body) { seq += "\033]" + body + "\033\\"; };
    auto hex = [](const QString &v) { return QByteArray("#") + v.toLatin1(); };
    osc("11;" + hex(palette["background"].toString()));
    osc("10;" + hex(palette["foreground"].toString()));
    osc("17;" + hex(palette["selectionBackground"].toString()));
    osc("19;" + hex(palette["selectionForeground"].toString()));
    const QStringList colors = palette["colors"].toStringList();
    for (int i = 0; i < colors.size() && i < 16; ++i) osc("4;" + QByteArray::number(i) + ";" + hex(colors[i]));
    const bool ok = ::write(fd, seq.constData(), size_t(seq.size())) == seq.size();
    ::close(fd);
    return ok;
}

bool Launcher::sendControlKey(QObject *seatObject, const QVariantList &keys, int times) const
{
    auto *seat = qobject_cast<QWaylandSeat *>(seatObject);
    if (!seat || !seat->keyboardFocus() || !seat->keyboard()) return false;
    int key = 0;
    for (const QVariant &k : keys) if (seat->keyboard()->keyToScanCode(k.toInt())) { key = k.toInt(); break; }
    if (!key) return false;
    for (int i = 0; i < qBound(1, times, 8); ++i) {
        QKeyEvent press(QEvent::KeyPress, key, Qt::ControlModifier), release(QEvent::KeyRelease, key, Qt::ControlModifier);
        seat->sendFullKeyEvent(&press); seat->sendFullKeyEvent(&release);
    }
    // a bare Shift tap: the press carries no modifiers, which resets the state the client last saw
    QKeyEvent shiftPress(QEvent::KeyPress, Qt::Key_Shift, Qt::NoModifier), shiftRelease(QEvent::KeyRelease, Qt::Key_Shift, Qt::NoModifier);
    seat->sendFullKeyEvent(&shiftPress); seat->sendFullKeyEvent(&shiftRelease);
    return true;
}

bool Launcher::hostCommand(const QString &cmd)
{
    QFile f(QStringLiteral("/mnt/share/host-cmd"));
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) { qWarning() << "host-cmd: share not writable"; return false; }
    f.write(cmd.toUtf8()); f.write("\n"); f.close();
    return true;
}

bool Launcher::fileExists(const QString &path) const { return QFile::exists(path); }
bool Launcher::writeFile(const QString &path, const QString &text) const
{
    QFile f(path + ".tmp");
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return false;
    f.write(text.toUtf8()); f.close();
    QFile::remove(path);
    return QFile::rename(path + ".tmp", path);
}
bool Launcher::removeFile(const QString &path) const { return QFile::remove(path); }
bool Launcher::setSeatFocus(QObject *seat, QObject *surface) const
{
    auto *s = qobject_cast<QWaylandSeat *>(seat); if (!s) return false;
    return s->setKeyboardFocus(surface ? qobject_cast<QWaylandSurface *>(surface) : nullptr);
}
QString Launcher::readFile(const QString &path) const { QFile f(path); return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.readAll()) : QString(); }
QString Launcher::hostClipboardText() const
{
    QFile f(QStringLiteral("/mnt/share/clipboard/mac.txt"));
    if (!f.open(QIODevice::ReadOnly) || f.size() > 1048576) return QString();
    return QString::fromUtf8(f.readAll());
}
