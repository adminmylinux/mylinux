#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QVector>
#include <QSocketNotifier>
#include <QTimer>
#include <QPoint>
#include <sys/types.h>
extern "C" {
#include <vterm.h>
}

// One SSH session: the OpenSSH client on a pseudo-terminal, its output fed to a libvterm screen. TermSurface paints
// the screen and sends keys here. A saved password is typed at ssh's first "password:" prompt; keys come from
// ~/.ssh (on the apps disk) or the key file given. The scrollback keeps the lines that leave the top of the screen.
class SshSession : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString host READ host NOTIFY changed)
    Q_PROPERTY(int port READ port NOTIFY changed)
    Q_PROPERTY(QString state READ state NOTIFY changed)          // idle | connecting | connected | closed | error
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString title READ title NOTIFY changed)          // what the remote shell set with OSC 0/2
    Q_PROPERTY(int rows READ rows NOTIFY changed)
    Q_PROPERTY(int cols READ cols NOTIFY changed)
    Q_PROPERTY(int scrollbackLines READ scrollbackLines NOTIFY changed)
public:
    explicit SshSession(QObject *parent = nullptr);
    ~SshSession() override;
    QString host() const { return m_host; }
    int port() const { return m_port; }
    QString state() const { return m_state; }
    QString error() const { return m_error; }
    QString title() const { return m_title; }
    int rows() const { return m_rows; }
    int cols() const { return m_cols; }
    int scrollbackLines() const { return m_scrollback.size(); }

    Q_INVOKABLE void open(const QString &host, int port, const QString &username, const QString &password, const QString &keyFile);
    Q_INVOKABLE void close();
    Q_INVOKABLE void resize(int rows, int cols);
    Q_INVOKABLE void sendText(const QString &text);              // paste: raw bytes to the remote
    void sendKey(VTermKey key, VTermModifier mod);
    void sendChar(uint32_t c, VTermModifier mod);

    // painting side
    VTermScreen *screen() const { return m_screen; }
    bool cellAt(int row, int col, VTermScreenCell &cell) const;   // row < 0 reaches into the scrollback
    QPoint cursor() const { return m_cursor; }
    bool cursorVisible() const { return m_cursorVisible && m_state == "connected"; }
signals:
    void changed();
    void damaged();                                                // repaint everything shown
    void bell();
private:
    static int cbDamage(VTermRect, void *);
    static int cbMoveCursor(VTermPos, VTermPos, int, void *);
    static int cbSetTermProp(VTermProp, VTermValue *, void *);
    static int cbBell(void *);
    static int cbPushLine(int, const VTermScreenCell *, void *);
    static int cbPopLine(int, VTermScreenCell *, void *);
    static void cbOutput(const char *, size_t, void *);
    void readPty();
    void ended();
    void setState(const QString &s, const QString &err = QString());

    VTerm *m_vt = nullptr;
    VTermScreen *m_screen = nullptr;
    int m_fd = -1;
    pid_t m_pid = 0;
    QSocketNotifier *m_notifier = nullptr;
    QTimer m_flush, m_settle;
    QString m_host, m_password, m_state = "idle", m_error, m_title;
    int m_port = 22, m_rows = 24, m_cols = 80;
    bool m_cursorVisible = true, m_passwordSent = false, m_damaged = false;
    QPoint m_cursor;
    QByteArray m_recent;                                         // the last output bytes, for the password prompt
    QVector<QVector<VTermScreenCell>> m_scrollback;
};
