#include "keygrab.h"
#include <QCoreApplication>
#include <QKeyEvent>

KeyGrab::KeyGrab(QObject *parent) : QObject(parent) { qApp->installEventFilter(this); }

bool KeyGrab::eventFilter(QObject *, QEvent *event)
{
    if (event->type() != QEvent::KeyPress && event->type() != QEvent::KeyRelease) return false;
    auto *ke = static_cast<QKeyEvent *>(event);
    if (!(ke->modifiers() & Qt::MetaModifier)) return false;
    if (ke->modifiers() & (Qt::ControlModifier | Qt::AltModifier)) return false;
    // libinput reports xkb key codes (evdev + 8): the digit row 1..9,0 is 10..19; accept raw evdev 2..11 as well.
    const int code = int(ke->nativeScanCode());
    int n = 0;
    if (code >= 10 && code <= 19) n = code - 9;
    else if (code >= 2 && code <= 11) n = code - 1;
    if (n == 0) return false;
    if (event->type() == QEvent::KeyPress && !ke->isAutoRepeat()) emit digit(n, ke->modifiers() & Qt::ShiftModifier);
    return true;    // swallow press and release so the client never sees the symbol
}
