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
public:
    explicit KeyGrab(QObject *parent = nullptr);
    bool eventFilter(QObject *watched, QEvent *event) override;
    int modifiers() const { return int(m_mods); }
signals:
    void digit(int n, bool shift);      // Super+n / Super+Shift+n, n = 1..9 (0 reads as 10)
    void modifiersChanged();
private:
    Qt::KeyboardModifiers m_mods;
};
