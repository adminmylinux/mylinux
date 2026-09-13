#include "keygrab.h"
#include <QCoreApplication>
#include <QKeyEvent>
#include <QDebug>
#include <QDateTime>

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
    // MYSHELL_KEYLOG=1 in the shell's environment: one log line per key press as the compositor receives it
    // (ShortcutOverride comes first, before any Shortcut can consume the key)
    static const bool keylog = qEnvironmentVariableIsSet("MYSHELL_KEYLOG");
    if (keylog && event->type() == QEvent::ShortcutOverride) {
        auto *k = static_cast<QKeyEvent *>(event);
        QString text; for (const QChar c : k->text()) text += c.isPrint() ? QString(c) : QString("\\x%1").arg(int(c.unicode()), 2, 16, QLatin1Char('0'));
        qInfo("keylog: %s key 0x%x mods 0x%x scan %u text '%s'", qPrintable(QDateTime::currentDateTime().toString("HH:mm:ss.zzz")), k->key(), unsigned(k->modifiers()), unsigned(k->nativeScanCode()), qPrintable(text));
    }
    const bool press = event->type() == QEvent::KeyPress;
    if (!press && event->type() != QEvent::KeyRelease) return false;
    auto *ke = static_cast<QKeyEvent *>(event);

    // Held modifiers: the event's modifier state, plus/minus the modifier key this event is about.
    Qt::KeyboardModifiers mods = ke->modifiers() & (Qt::MetaModifier | Qt::ShiftModifier | Qt::ControlModifier | Qt::AltModifier);
    if (Qt::KeyboardModifier m = modifierOf(ke->key())) { if (press) mods |= m; else mods &= ~m; }
    if (mods != m_mods) { m_mods = mods; emit modifiersChanged(); }

    if (m_grabbed) return false;                                 // grabbed: the client gets everything, digits included
    if (!(ke->modifiers() & Qt::MetaModifier)) return false;
    if (ke->modifiers() & Qt::ControlModifier) return false;
    // The launcher menu: Super+Space (xkb 65) and Super+Esc (xkb 9), plain Super only.
    if (!(ke->modifiers() & (Qt::AltModifier | Qt::ShiftModifier)) && (ke->nativeScanCode() == 65 || ke->nativeScanCode() == 9)) {
        if (press && !ke->isAutoRepeat()) emit menu();
        return true;
    }
    if ((ke->modifiers() & Qt::AltModifier) && !(ke->modifiers() & Qt::ShiftModifier)) return false;   // Super+Alt+n is free
    // libinput reports xkb key codes (evdev + 8): the digit row 1..9,0 is 10..19. No raw-evdev fallback: in xkb
    // numbering 9 is Escape, and a fallback for 2..11 turned Super+Esc into "workspace 8" and swallowed it.
    const int code = int(ke->nativeScanCode());
    const int n = (code >= 10 && code <= 19) ? code - 9 : 0;
    if (n == 0) return false;
    if (press && !ke->isAutoRepeat()) emit digit(n, ke->modifiers() & Qt::ShiftModifier, ke->modifiers() & Qt::AltModifier);
    return true;    // swallow press and release so the client never sees the symbol
}
