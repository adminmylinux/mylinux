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

    qputenv("QT_QPA_PLATFORM", qgetenv("MYSHELL_PLATFORM").isEmpty() ? "eglfs" : qgetenv("MYSHELL_PLATFORM"));
    QGuiApplication app(argc, argv);
    app.setApplicationName("myshell");

    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("MyShell", "Main");
    return app.exec();
}
