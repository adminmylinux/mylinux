#include "themestore.h"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QDirIterator>
#include <QImage>
#include <QLibrary>
#include <QDebug>
#include <algorithm>

static const QStringList kDirs = { "/usr/share/mylinux/themes", "/root/.config/mylinux/themes" };   // /root is the apps disk when mounted

static QString titleCase(QString id)
{
    QStringList parts = id.split('-', Qt::SkipEmptyParts);
    for (QString &p : parts) p[0] = p[0].toUpper();
    return parts.join(' ');
}

ThemeStore::ThemeStore(QObject *parent) : QObject(parent) { rescan(); }

void ThemeStore::rescan()
{
    QMap<QString, QVariantMap> byId;
    QStringList order;
    for (const QString &base : kDirs) {
        QDir d(base); if (!d.exists()) continue;
        for (const QString &id : d.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
            QFile f(base + "/" + id + "/colors.toml"); if (!f.open(QIODevice::ReadOnly)) continue;
            QVariantMap colors;
            for (const QByteArray &line : f.readAll().split('\n')) {
                const int eq = line.indexOf('='); if (eq < 0) continue;
                QString k = line.left(eq).trimmed(), v = line.mid(eq + 1).trimmed(); v.remove('"');
                if (!k.isEmpty() && v.startsWith('#')) colors[k] = v;
            }
            if (!colors.contains("background")) continue;
            // Omarchy 3 palettes use named colours + mode=; normalise to color0..15 (terminal + swatches)
            auto def = [&](const char *k, const char *from, const char *fallback) {
                if (!colors.contains(k)) colors[k] = colors.contains(from) ? colors[from] : colors.value(fallback, colors["foreground"]);
            };
            def("color0", "muted", "darker_background"); def("color1", "red", "foreground"); def("color2", "green", "foreground");
            def("color3", "yellow", "foreground"); def("color4", "blue", "accent"); def("color5", "magenta", "accent");
            def("color6", "cyan", "accent"); def("color7", "light_foreground", "foreground"); def("color8", "dark_foreground", "muted");
            def("color9", "bright_red", "color1"); def("color10", "bright_green", "color2"); def("color11", "bright_yellow", "color3");
            def("color12", "bright_blue", "color4"); def("color13", "bright_magenta", "color5"); def("color14", "bright_cyan", "color6");
            def("color15", "bright_foreground", "foreground");
            def("selection_background", "selection", "color0"); def("selection_foreground", "bright_foreground", "foreground");
            if (!colors.contains("accent")) colors["accent"] = colors["color4"];
            QVariantMap t;
            t["id"] = id; t["name"] = titleCase(id); t["dir"] = base + "/" + id;
            QString mode;
            { QFile m(base + "/" + id + "/colors.toml"); if (m.open(QIODevice::ReadOnly)) { const QString all = m.readAll(); QRegularExpressionMatch mm = QRegularExpression("^mode\\s*=\\s*\"(\\w+)\"", QRegularExpression::MultilineOption).match(all); if (mm.hasMatch()) mode = mm.captured(1); } }
            t["light"] = QFileInfo(base + "/" + id + "/light.mode").exists() || mode == "light";
            t["colors"] = colors;
            QStringList bgs;
            QDir bd(base + "/" + id + "/backgrounds");
            if (!bd.entryList({"*.webp"}, QDir::Files).isEmpty()) convertWebp(bd.path());   // e.g. downloaded by an older script
            for (const QString &b : bd.entryList({"*.png", "*.jpg", "*.jpeg"}, QDir::Files, QDir::Name)) bgs << bd.filePath(b);
            t["backgrounds"] = bgs;
            if (byId.contains(id)) {          // later dirs (user) override colours; their backgrounds come first
                QVariantMap prev = byId[id];
                QStringList all = bgs; all << prev["backgrounds"].toStringList();
                t["backgrounds"] = all;
            } else order << id;
            byId[id] = t;
        }
    }
    QVariantList list;
    for (const QString &id : order) list << byId[id];
    m_themes = list; emit changed();
}

QVariantMap ThemeStore::theme(const QString &id) const
{
    for (const QVariant &v : m_themes) if (v.toMap()["id"] == id) return v.toMap();
    return m_themes.isEmpty() ? QVariantMap() : m_themes.first().toMap();
}

void ThemeStore::applyTerminal(const QString &id, int fontPt)
{
    const QVariantMap t = theme(id); if (t.isEmpty()) return;
    const QVariantMap c = t["colors"].toMap();
    auto col = [&](const char *k, const char *def) { return c.value(k, def).toString().mid(1); };   // foot wants no '#'
    QString ini = QStringLiteral("font=DejaVu Sans Mono:size=%1\npad=10x8\ninitial-window-size-pixels=760x440\n[csd]\npreferred=none\n").arg(fontPt);
    QString colors = QStringLiteral("alpha=0.97\nbackground=%1\nforeground=%2\nselection-foreground=%3\nselection-background=%4\n")
               .arg(col("background", "#1e1e1e"), col("foreground", "#e6e6e6"), col("selection_foreground", "#ffffff"), col("selection_background", "#444444"));
    for (int i = 0; i < 8; ++i) colors += QStringLiteral("regular%1=%2\n").arg(i).arg(col(QByteArray("color" + QByteArray::number(i)).constData(), "#888888"));
    for (int i = 0; i < 8; ++i) colors += QStringLiteral("bright%1=%2\n").arg(i).arg(col(QByteArray("color" + QByteArray::number(i + 8)).constData(), "#aaaaaa"));
    // foot 1.26 wants the per-mode sections (plain [colors] is deprecated); we use one palette for both
    ini += "[colors-dark]\n" + colors + "[colors-light]\n" + colors;
    QFile f("/etc/xdg/foot/foot.ini");
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) { f.write(ini.toUtf8()); f.close(); }
    else qWarning() << "theme: cannot write foot.ini";
}

int ThemeStore::convertWebp(const QString &dir)
{
    QLibrary lib(QStringLiteral("webp"));
    if (!lib.load()) lib.setFileName(QStringLiteral("/usr/lib/libwebp.so.7")), lib.load();
    typedef int (*GetInfoFn)(const uint8_t *, size_t, int *, int *);
    typedef uint8_t *(*DecodeFn)(const uint8_t *, size_t, int *, int *);
    typedef void (*FreeFn)(void *);
    auto getInfo = (GetInfoFn)lib.resolve("WebPGetInfo");
    auto decode = (DecodeFn)lib.resolve("WebPDecodeRGBA");
    auto wfree = (FreeFn)lib.resolve("WebPFree");
    if (!getInfo || !decode) { qWarning() << "libwebp not available"; return -1; }
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
        QImage img = QImage(rgba, w, h, w * 4, QImage::Format_RGBA8888).copy();
        // Wallpapers are shown at screen size; 5000-px photos only cost decode time and texture memory.
        if (img.width() > 2560) img = img.scaled(2560, 2560 * img.height() / img.width(), Qt::KeepAspectRatio, Qt::SmoothTransformation);
        const QString out = path.left(path.size() - 5) + ".png";
        if (img.save(out, "PNG")) { QFile::remove(path); ++done; }
        if (wfree) wfree(rgba); else free(rgba);
    }
    return done;
}
