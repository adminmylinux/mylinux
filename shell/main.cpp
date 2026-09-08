#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QDebug>
#include "themestore.h"

int main(int argc, char *argv[])
{
    if (argc >= 3 && QString::fromLatin1(argv[1]) == "--convert-webp") {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        QGuiApplication app(argc, argv);
        const int n = ThemeStore::convertWebp(QString::fromLocal8Bit(argv[2]));
        qInfo() << "converted" << n << "webp images in" << argv[2];
        return n < 0 ? 1 : 0;
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
