#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QStringList>

// Starts Wayland client programs from QML with a clean environment.
class Launcher : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
public:
    explicit Launcher(QObject *parent = nullptr);
    Q_INVOKABLE bool launch(const QString &program, const QStringList &args = {});
    Q_INVOKABLE QString socketName() const;
    // switch a running foot terminal between its two palettes (SIGUSR1 theme, SIGUSR2 high contrast); only a
    // process whose name is foot is signalled
    // Recolour a running foot terminal (ThemeStore.terminalPalette map) by writing OSC 10/11/17/19/4 sequences to the
    // pty of its shell: foot has no config reload, and its two built-in palettes cannot express three modes.
    Q_INVOKABLE bool setTerminalPalette(qint64 pid, const QVariantMap &palette);
    // Ctrl+<key> to the seat's keyboard focus, `times` times, with the modifier state the client sees (QML's
    // WaylandSeat.sendKeyEvent sends bare keys). The first of `keys` that exists unshifted on the layout is used.
    Q_INVOKABLE bool sendControlKey(QObject *seat, const QVariantList &keys, int times) const;
    Q_INVOKABLE bool hostCommand(const QString &cmd);
    Q_INVOKABLE bool fileExists(const QString &path) const;
    Q_INVOKABLE bool writeFile(const QString &path, const QString &text) const;   // atomic (tmp + rename)
    Q_INVOKABLE bool removeFile(const QString &path) const;
    Q_INVOKABLE QString readFile(const QString &path) const;
    // The Mac clipboard as mirrored by run.sh (share/clipboard/mac.txt): the shell's own text fields paste from it
    // with Ctrl+V / ⌘V, since the compositor has no system clipboard of its own on eglfs.
    Q_INVOKABLE QString hostClipboardText() const;
    // Seat keyboard focus from C++: assigning null to the seat's keyboardFocus property in QML is a no-op.
    Q_INVOKABLE bool setSeatFocus(QObject *seat, QObject *surface) const;
signals:
    void launched(const QString &program, qint64 pid);
    void failed(const QString &program, const QString &error);
};
