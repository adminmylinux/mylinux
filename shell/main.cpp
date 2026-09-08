#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QDirIterator>
#include <QFile>
#include <QImage>
#include <QLibrary>
#include <QDebug>

// `myshell --convert-webp <dir>`: turn every *.webp under <dir> into a .png (Qt here has no WebP
// plugin; libwebp is in the image, loaded at runtime so the build needs no headers).
static int convertWebp(const QString &dir)
{
    QLibrary lib(QStringLiteral("webp"));
    if (!lib.load()) lib.setFileName(QStringLiteral("/usr/lib/libwebp.so.7")), lib.load();
    typedef int (*GetInfoFn)(const uint8_t *, size_t, int *, int *);
    typedef uint8_t *(*DecodeFn)(const uint8_t *, size_t, int *, int *);
    typedef void (*FreeFn)(void *);
    auto getInfo = (GetInfoFn)lib.resolve("WebPGetInfo");
    auto decode = (DecodeFn)lib.resolve("WebPDecodeRGBA");
    auto wfree = (FreeFn)lib.resolve("WebPFree");
    if (!getInfo || !decode) { qWarning() << "libwebp not available"; return 1; }
    int done = 0;
    QDirIterator it(dir, {"*.webp"}, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString path = it.next();
        QFile f(path); if (!f.open(QIODevice::ReadOnly)) continue;
        const QByteArray data = f.readAll(); f.close();
        int w = 0, h = 0;
        if (!getInfo((const uint8_t *)data.constData(), data.size(), &w, &h)) continue;
        uint8_t *rgba = decode((const uint8_t *)data.constData(), data.size(), &w, &h);
        if (!rgba) continue;
        QImage img(rgba, w, h, w * 4, QImage::Format_RGBA8888);
        const QString out = path.left(path.size() - 5) + ".png";
        if (img.copy().save(out, "PNG")) { QFile::remove(path); ++done; }
        if (wfree) wfree(rgba); else free(rgba);
    }
    qInfo() << "converted" << done << "webp images in" << dir;
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc >= 3 && QString::fromLatin1(argv[1]) == "--convert-webp") {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        QGuiApplication app(argc, argv);
        return convertWebp(QString::fromLocal8Bit(argv[2]));
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
