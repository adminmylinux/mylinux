#include "themestore.h"
#include <QColor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QDirIterator>
#include <QImage>
#include <QLibrary>
#include <QThreadPool>
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
    QStringList order, toConvert;
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
            if (!bd.entryList({"*.webp"}, QDir::Files).isEmpty()) toConvert << bd.path();   // e.g. downloaded by an older script
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
    if (!toConvert.isEmpty()) convertLater(toConvert);
}

// Decoding and re-encoding wallpapers takes seconds per image: never on the compositor thread. One batch
// at a time; the picker shows "converting" meanwhile and the list refreshes when the PNGs exist.
void ThemeStore::convertLater(const QStringList &dirs)
{
    if (m_converting) return;
    m_converting = true; emit changed();
    QThreadPool::globalInstance()->start([this, dirs] {
        for (const QString &d : dirs) convertWebp(d);
        QMetaObject::invokeMethod(this, [this] { m_converting = false; rescan(); }, Qt::QueuedConnection);
    });
}


QVariantMap ThemeStore::theme(const QString &id) const
{
    for (const QVariant &v : m_themes) if (v.toMap()["id"] == id) return v.toMap();
    return m_themes.isEmpty() ? QVariantMap() : m_themes.first().toMap();
}

// High contrast from a theme colour: on a dark background everything is pushed towards white (and fully
// saturated hues keep their identity), on a light one towards black. Slot 0/8 (black) and 7/15 (white) become the
// extremes, so `ls` and prompt colours stay legible even when the terminal is drawn small.
QString ThemeStore::contrastColor(const QString &hex, bool darkBackground, int slot)
{
    const int base = slot % 8;
    if (base == 0) return darkBackground ? (slot < 8 ? "000000" : "9a9a9a") : (slot < 8 ? "000000" : "3a3a3a");
    if (base == 7) return darkBackground ? "ffffff" : (slot < 8 ? "1a1a1a" : "000000");
    QColor c(QLatin1Char('#') + hex);
    if (!c.isValid()) return darkBackground ? "ffffff" : "000000";
    float h, sat, l, a; c.getHslF(&h, &sat, &l, &a);
    if (darkBackground) l = qMax(l, slot < 8 ? 0.68f : 0.80f);
    else l = qMin(l, slot < 8 ? 0.30f : 0.22f);
    sat = qMax(sat, 0.55f);
    return QColor::fromHslF(h, sat, l).name().mid(1);
}

// The terminal palette for a mode: "normal" is the theme's own colours, "contrast" the theme's hues on an opaque
// black or white ground (ThemeStore::contrastColor), "retro" a green-phosphor monochrome. Keys: background,
// foreground, selectionBackground, selectionForeground, alpha, colors (16 hex strings, no '#').
QVariantMap ThemeStore::terminalPalette(const QString &id, const QString &mode) const
{
    QVariantMap p;
    QStringList colors;
    if (mode == "retro") {
        p["background"] = "000000"; p["foreground"] = "33ff33"; p["selectionBackground"] = "33ff33"; p["selectionForeground"] = "000000"; p["alpha"] = 1.0;
        colors = { "003300", "22aa22", "33ff33", "88ff88", "119911", "55dd55", "44cc44", "33ff33",
                   "226622", "66ff66", "55ff55", "aaffaa", "33cc33", "99ff99", "77ee77", "ccffcc" };
    } else {
        const QVariantMap t = theme(id);
        const QVariantMap c = t["colors"].toMap();
        auto col = [&](const char *k, const char *def) { return c.value(k, def).toString().mid(1); };   // foot wants no '#'
        const bool dark = QColor(QLatin1Char('#') + col("background", "#1e1e1e")).lightnessF() < 0.5;
        for (int i = 0; i < 16; ++i) colors << col(QByteArray("color" + QByteArray::number(i)).constData(), i < 8 ? "#888888" : "#aaaaaa");
        if (mode == "contrast") {
            p["background"] = dark ? "000000" : "ffffff"; p["foreground"] = dark ? "ffffff" : "000000";
            p["selectionBackground"] = dark ? "ffffff" : "000000"; p["selectionForeground"] = dark ? "000000" : "ffffff"; p["alpha"] = 1.0;
            for (int i = 0; i < 16; ++i) colors[i] = contrastColor(colors[i], dark, i);
        } else {
            p["background"] = col("background", "#1e1e1e"); p["foreground"] = col("foreground", "#e6e6e6");
            p["selectionBackground"] = col("selection_background", "#444444"); p["selectionForeground"] = col("selection_foreground", "#ffffff"); p["alpha"] = 0.97;
        }
    }
    p["colors"] = colors;
    return p;
}

void ThemeStore::applyTerminal(const QString &id, double fontPt, const QString &mode)
{
    const QVariantMap p = terminalPalette(id, mode);
    fontPt = qBound(4.0, fontPt, 60.0);
    QString ini = QStringLiteral("font=DejaVu Sans Mono:size=%1\npad=10x8\ninitial-window-size-pixels=760x440\n# zooming (the title bar settings, Ctrl+plus/minus) keeps the window size: tiled terminals must not grow\nresize-keep-grid=no\n[csd]\npreferred=none\n")
                      .arg(QString::number(fontPt, 'g', 3));
    QString colors = QStringLiteral("alpha=%1\nbackground=%2\nforeground=%3\nselection-foreground=%4\nselection-background=%5\n")
               .arg(QString::number(p["alpha"].toDouble(), 'g', 3), p["background"].toString(), p["foreground"].toString(), p["selectionForeground"].toString(), p["selectionBackground"].toString());
    const QStringList c = p["colors"].toStringList();
    for (int i = 0; i < 16; ++i) colors += QStringLiteral("%1%2=%3\n").arg(i < 8 ? "regular" : "bright").arg(i % 8).arg(c[i]);
    // foot 1.26 wants [colors-dark] / [colors-light]; running terminals are recoloured with OSC sequences instead
    // (Launcher.setTerminalPalette), so both sections carry the one selected palette
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
