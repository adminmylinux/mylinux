#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDebug>

// vncview: a small, fast VNC viewer for myLinux (tabs, fullscreen, the compositor grabs all keys while
// fullscreen). Usage: vncview [host[:port]] [name]
int main(int argc, char *argv[])
{
    qputenv("QT_QPA_PLATFORM", "wayland");                  // a Wayland client of the shell, even from a terminal
    if (qgetenv("QT_QUICK_BACKEND").isEmpty()) qputenv("QT_QUICK_BACKEND", "software");
    qputenv("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1");
    QGuiApplication app(argc, argv);
    app.setApplicationName("vncview");
    app.setDesktopFileName("vncview");                      // the Wayland app id the compositor's grab rule looks for
    QString host, name; int port = 5900;
    const QStringList args = app.arguments().mid(1);
    if (!args.isEmpty() && !args[0].startsWith('-')) {
        const QString a = args[0]; const int c = a.lastIndexOf(':');
        if (c > 0 && a.mid(c + 1).toInt() > 0) { host = a.left(c); port = a.mid(c + 1).toInt(); } else host = a;
        if (args.size() > 1) name = args[1];
    }
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("startHost", host);
    engine.rootContext()->setContextProperty("startPort", port);
    engine.rootContext()->setContextProperty("startName", name);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("VncView", "Main");
    return app.exec();
}
