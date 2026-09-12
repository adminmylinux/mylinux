#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QVariantList>
#include <QVariantMap>
#include <QFileSystemWatcher>
#include <QTimer>
#include <QProcess>
#include <QHash>
#include <QJsonObject>

// User-defined menu bar modules, in the shape of Omarchy's bar modules: a directory of <id>.json descriptors,
//   { "id": "vpn", "type": "command", "exec": "~/.config/mylinux/bar/scripts/vpn-status", "interval": 5, "tooltip": "VPN" }
//   { "id": "gpu", "type": "qml" }            -> <id>.qml next to it, loaded into the bar (full QML, MyShell singletons available)
// Command modules run through the apps disk (apps-run sh -c) so Debian tools work; the first line of stdout is the
// text, or a JSON object { "text", "tooltip", "color", "class" }. "on-click" runs the same way. Directories:
//   ~/.config/mylinux/bar/modules  (yours, on the apps disk)      /usr/share/mylinux/bar/modules (shipped)
// Files are watched: editing a descriptor or a QML file reloads that module (hot reload). Modules are user
// code running inside the shell, like Omarchy plugins: nothing sandboxes them.
class BarModules : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QVariantList modules READ modules NOTIFY changed)
    Q_PROPERTY(int revision READ revision NOTIFY changed)        // bumps on every rescan (QML loaders re-read)
    Q_PROPERTY(QString userDir READ userDir CONSTANT)
public:
    explicit BarModules(QObject *parent = nullptr);
    QVariantList modules() const { return m_list; }
    int revision() const { return m_revision; }
    QString userDir() const;
    Q_INVOKABLE void rescan();
    Q_INVOKABLE void run(const QString &id);                     // refresh one command module now
    Q_INVOKABLE void click(const QString &id);                   // its on-click command
    Q_INVOKABLE bool installExamples();                          // copy the shipped examples into the user dir
    Q_INVOKABLE void report(const QString &id, const QString &text, const QString &tooltip);   // QML modules publish their state (diagnostics, tests)
    static QVariantMap parseOutput(const QByteArray &out);       // text / tooltip / color from a command's stdout
    static QVariantMap parseDescriptor(const QJsonObject &o, const QString &dir);
signals:
    void changed();
private:
    struct Mod { QVariantMap desc; QProcess *proc = nullptr; QTimer *timer = nullptr; };
    void publish();
    void startCommand(const QString &id);
    QStringList dirs() const;
    QHash<QString, Mod> m_mods;
    QStringList m_order;
    QVariantList m_list;
    QString signature() const;                                   // paths + mtimes of every descriptor and QML file
    QFileSystemWatcher m_watcher;
    QTimer m_debounce, m_poll;
    QString m_sig;
    int m_revision = 0;
};
