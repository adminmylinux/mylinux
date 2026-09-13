#pragma once
#include <QObject>
#include <QQmlEngine>

// Application-wide key filter. Two jobs:
//  - Super+digit / Super+Shift+digit shortcuts, matched by physical key code (with Shift the layout turns
//    the digit keys into symbols, which QML's Shortcut cannot match);
//  - the currently held modifier keys, for UI that reacts to them (the ⌘K key sheet highlights the
//    bindings of the modifiers you hold).
class KeyGrab : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int modifiers READ modifiers NOTIFY modifiersChanged)
    Q_PROPERTY(bool grabbed READ grabbed WRITE setGrabbed NOTIFY grabbedChanged)   // every key goes to the focused client (VNC viewer): no Super shortcuts
public:
    explicit KeyGrab(QObject *parent = nullptr);
    bool eventFilter(QObject *watched, QEvent *event) override;
    int modifiers() const { return int(m_mods); }
    bool grabbed() const { return m_grabbed; }
    void setGrabbed(bool g) { if (g == m_grabbed) return; m_grabbed = g; emit grabbedChanged(); }
signals:
    void digit(int n, bool shift, bool alt);   // Super+n, Super+Shift+n, Super+Shift+Alt+n; n = 1..9 (0 reads as 10)
    void menu();                               // Super+Space / Super+Esc, by key code (independent of QShortcutMap and the xkb layout)
    void modifiersChanged();
    void grabbedChanged();
private:
    bool m_grabbed = false;
    Qt::KeyboardModifiers m_mods;
};
