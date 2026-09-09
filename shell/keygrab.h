#pragma once
#include <QObject>
#include <QQmlEngine>

// Application-wide key filter for shortcuts that QML's Shortcut cannot match reliably: Super+digit and
// Super+Shift+digit. With Shift held the keyboard layout turns the digit keys into symbols (# " ¤ ...),
// so we look at the physical key (evdev/xkb key code) instead of the translated key.
class KeyGrab : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
public:
    explicit KeyGrab(QObject *parent = nullptr);
    bool eventFilter(QObject *watched, QEvent *event) override;
signals:
    void digit(int n, bool shift);      // Super+n / Super+Shift+n, n = 1..9 (0 reads as 10)
};
