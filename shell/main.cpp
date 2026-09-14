#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QDebug>
#include "themestore.h"
#include "agentusage.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QFile>
#include <QDate>
#include <cstdio>
#include <string>
#include <csignal>
#include <cstring>
#include <ctime>
#include <execinfo.h>
#include <fcntl.h>
#include <unistd.h>

// A crash leaves the report shell-run copies to share/shell-exits.log: the signal, a backtrace (addresses resolve with
// addr2line against the unstripped build, using the load address from the maps lines) and the mappings.
static void writeStr(int fd, const char *s) { if (write(fd, s, strlen(s)) < 0) {} }
static void onFatalSignal(int sig)
{
    int fd = open("/run/mylinux-shell/crash.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char line[96];
        snprintf(line, sizeof line, "myshell: fatal signal %d (%s) at %ld\n", sig, strsignal(sig), long(time(nullptr)));
        writeStr(fd, line);
        void *frames[64];
        const int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
        writeStr(fd, "-- maps (myshell, Qt)\n");
        int maps = open("/proc/self/maps", O_RDONLY);
        if (maps >= 0) {
            char buf[4096]; ssize_t r;
            // only the lines naming the binary or Qt libraries keep the report short
            std::string pending;
            while ((r = read(maps, buf, sizeof buf)) > 0) {
                pending.append(buf, size_t(r));
                size_t nl;
                while ((nl = pending.find('\n')) != std::string::npos) {
                    const std::string l = pending.substr(0, nl + 1); pending.erase(0, nl + 1);
                    if (l.find("myshell") != std::string::npos || l.find("libQt6") != std::string::npos) writeStr(fd, l.c_str());
                }
            }
            close(maps);
        }
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

int main(int argc, char *argv[])
{
    if (argc >= 3 && QString::fromLatin1(argv[1]) == "--convert-webp") {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        QGuiApplication app(argc, argv);
        const int n = ThemeStore::convertWebp(QString::fromLocal8Bit(argv[2]));
        qInfo() << "converted" << n << "webp images in" << argv[2];
        return n < 0 ? 1 : 0;
    }
    // Test hooks (tools/vmtest): scan agent logs under a directory as JSON, parse a saved limits payload.
    if (argc >= 3 && QString::fromLatin1(argv[1]) == "--agent-scan") {
        const QDate today = argc >= 4 ? QDate::fromString(QString::fromLatin1(argv[3]), Qt::ISODate) : QDate::currentDate();
        const AgentScanResult r = AgentUsage::scan(QString::fromLocal8Bit(argv[2]), {}, today);
        QJsonObject o; o["claude"] = QJsonObject::fromVariantMap(r.claude); o["codex"] = QJsonObject::fromVariantMap(r.codex); o["cachedFiles"] = r.cache.size();
        printf("%s\n", QJsonDocument(o).toJson(QJsonDocument::Compact).constData());
        return 0;
    }
    if (argc >= 3 && QString::fromLatin1(argv[1]) == "--claude-limits") {
        QFile f(QString::fromLocal8Bit(argv[2])); if (!f.open(QIODevice::ReadOnly)) return 1;
        const QVariantList lim = AgentUsage::parseClaudeLimits(QJsonDocument::fromJson(f.readAll()).object());
        printf("%s\n", QJsonDocument(QJsonArray::fromVariantList(lim)).toJson(QJsonDocument::Compact).constData());
        return 0;
    }
    // The compositor itself runs on eglfs (KMS); its clients talk Wayland.

    for (int sig : {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT}) signal(sig, onFatalSignal);
    backtrace(nullptr, 0);      // loads libgcc now: the first backtrace() call allocates, which a crashed heap may not survive

    qputenv("QT_QPA_PLATFORM", qgetenv("MYSHELL_PLATFORM").isEmpty() ? "eglfs" : qgetenv("MYSHELL_PLATFORM"));
    QGuiApplication app(argc, argv);
    app.setApplicationName("myshell");

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("MyShell", "Main");
    return app.exec();
}
