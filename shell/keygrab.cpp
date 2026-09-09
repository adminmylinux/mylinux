#include "keygrab.h"
#include <QCoreApplication>
#include <QKeyEvent>

KeyGrab::KeyGrab(QObject *parent) : QObject(parent) { qApp->installEventFilter(this); }

static Qt::KeyboardModifier modifierOf(int key)
{
    switch (key) {
    case Qt::Key_Meta: case Qt::Key_Super_L: case Qt::Key_Super_R: return Qt::MetaModifier;   // xkb reports Super_L, not Meta
    case Qt::Key_Shift: return Qt::ShiftModifier;
    case Qt::Key_Control: return Qt::ControlModifier;
    case Qt::Key_Alt: case Qt::Key_AltGr: return Qt::AltModifier;
    default: return Qt::NoModifier;
    }
}

bool KeyGrab::eventFilter(QObject *, QEvent *event)
{
    const bool press = event->type() == QEvent::KeyPress;
    if (!press && event->type() != QEvent::KeyRelease) return false;
    auto *ke = static_cast<QKeyEvent *>(event);

    // Held modifiers: the event's modifier state, plus/minus the modifier key this event is about.
    Qt::KeyboardModifiers mods = ke->modifiers() & (Qt::MetaModifier | Qt::ShiftModifier | Qt::ControlModifier | Qt::AltModifier);
    if (Qt::KeyboardModifier m = modifierOf(ke->key())) { if (press) mods |= m; else mods &= ~m; }
    if (mods != m_mods) { m_mods = mods; emit modifiersChanged(); }

    if (!(ke->modifiers() & Qt::MetaModifier)) return false;
    if (ke->modifiers() & Qt::ControlModifier) return false;
    if ((ke->modifiers() & Qt::AltModifier) && !(ke->modifiers() & Qt::ShiftModifier)) return false;   // Super+Alt+n is free
    // libinput reports xkb key codes (evdev + 8): the digit row 1..9,0 is 10..19; accept raw evdev 2..11 as well.
    const int code = int(ke->nativeScanCode());
    int n = 0;
    if (code >= 10 && code <= 19) n = code - 9;
    else if (code >= 2 && code <= 11) n = code - 1;
    if (n == 0) return false;
    if (press && !ke->isAutoRepeat()) emit digit(n, ke->modifiers() & Qt::ShiftModifier, ke->modifiers() & Qt::AltModifier);
    return true;    // swallow press and release so the client never sees the symbol
}
