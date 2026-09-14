#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>

// Themes on disk (/usr/share/mylinux/themes/<id>/colors.toml [+ light.mode] [+ backgrounds/*.png]),
// Omarchy-compatible palette format.
class ThemeStore : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantList themes READ themes NOTIFY changed)
    Q_PROPERTY(bool converting READ converting NOTIFY changed)   // WebP backgrounds being converted in a worker thread
public:
    explicit ThemeStore(QObject *parent = nullptr);
    QVariantList themes() const { return m_themes; }
    bool converting() const { return m_converting; }
    Q_INVOKABLE QVariantMap theme(const QString &id) const;
    Q_INVOKABLE void rescan();
    // rewrite foot.ini: font size (fractional), the theme palette as [colors-dark] and a high-contrast palette derived
    // from it as [colors-light]; initial-color-theme picks one for new terminals, SIGUSR1/2 switch running ones
    Q_INVOKABLE void applyTerminal(const QString &id, double fontPt, const QString &mode = "normal");
    Q_INVOKABLE QVariantMap terminalPalette(const QString &id, const QString &mode) const;   // normal | contrast | retro
    static QString contrastColor(const QString &hex, bool darkBackground, int slot);   // exposed for tests
    // Convert every *.webp under dir to .png (libwebp loaded at runtime; Qt has no WebP plugin here).
    // Returns the number converted, -1 if libwebp is missing.
    static int convertWebp(const QString &dir);
signals:
    void changed();
private:
    void convertLater(const QStringList &dirs);   // off the UI thread; rescans when done
    QVariantList m_themes;
    bool m_converting = false;
};

