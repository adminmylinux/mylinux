#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName("myapp");

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("qtVersion", QStringLiteral(QT_VERSION_STR));
    engine.rootContext()->setContextProperty("appPath", QCoreApplication::applicationFilePath());
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("MyApp", "Main");
    return app.exec();
}
