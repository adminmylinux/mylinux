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
public:
    explicit ThemeStore(QObject *parent = nullptr);
    QVariantList themes() const { return m_themes; }
    Q_INVOKABLE QVariantMap theme(const QString &id) const;
    Q_INVOKABLE void rescan();
    Q_INVOKABLE void applyTerminal(const QString &id, int fontPt);   // rewrite foot.ini colours + font
    // Convert every *.webp under dir to .png (libwebp loaded at runtime; Qt has no WebP plugin here).
    // Returns the number converted, -1 if libwebp is missing.
    static int convertWebp(const QString &dir);
signals:
    void changed();
private:
    QVariantList m_themes;
};
