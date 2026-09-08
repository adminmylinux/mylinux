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
    Q_INVOKABLE bool fileExists(const QString &path) const;   // ask the host agent (run.sh) to do something
signals:
    void launched(const QString &program, qint64 pid);
    void failed(const QString &program, const QString &error);
};
