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
    Q_INVOKABLE void setTerminalFont(int pt);
    Q_INVOKABLE bool hostCommand(const QString &cmd);
    Q_INVOKABLE bool fileExists(const QString &path) const;
    Q_INVOKABLE bool writeFile(const QString &path, const QString &text) const;   // atomic (tmp + rename)
    Q_INVOKABLE bool removeFile(const QString &path) const;
    Q_INVOKABLE QString readFile(const QString &path) const;
    // Seat keyboard focus from C++: assigning null to the seat's keyboardFocus property in QML is a no-op.
    Q_INVOKABLE bool setSeatFocus(QObject *seat, QObject *surface) const;
signals:
    void launched(const QString &program, qint64 pid);
    void failed(const QString &program, const QString &error);
};
