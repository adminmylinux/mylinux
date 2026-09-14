#include "sshsession.h"
#include <QDebug>
#include <QFile>
#include <pty.h>
#include <unistd.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <errno.h>
#include <cstring>

static const int kScrollbackMax = 5000;

SshSession::SshSession(QObject *parent) : QObject(parent)
{
    m_flush.setSingleShot(true); m_flush.setInterval(8);
    connect(&m_flush, &QTimer::timeout, this, [this] { if (m_damaged) { m_damaged = false; emit damaged(); } });
    m_settle.setSingleShot(true); m_settle.setInterval(400);
    connect(&m_settle, &QTimer::timeout, this, [this] {
        if (m_state != "connecting") return;
        const QByteArray tail = m_recent.trimmed().toLower();
        const bool prompt = tail.endsWith("password:") || tail.endsWith("passphrase:") || tail.contains("(yes/no") || tail.endsWith("?");
        if (!prompt && !tail.isEmpty()) setState("connected");
    });
}

SshSession::~SshSession() { close(); }

void SshSession::setState(const QString &s, const QString &err)
{
    m_state = s; m_error = err;
    qInfo("ssh: state %s%s%s", qPrintable(s), err.isEmpty() ? "" : ": ", qPrintable(err));
    emit changed(); emit damaged();
}

void SshSession::open(const QString &host, int port, const QString &username, const QString &password, const QString &keyFile, const QString &tmux)
{
    close();
    m_host = host; m_port = port > 0 ? port : 22; m_password = password; m_passwordSent = false; m_recent.clear();
    m_scrollback.clear(); m_title.clear();

    m_vt = vterm_new(m_rows, m_cols);
    vterm_set_utf8(m_vt, 1);
    vterm_output_set_callback(m_vt, cbOutput, this);
    m_screen = vterm_obtain_screen(m_vt);
    static const VTermScreenCallbacks cbs = { cbDamage, nullptr, cbMoveCursor, cbSetTermProp, cbBell, nullptr, cbPushLine, cbPopLine, nullptr };
    vterm_screen_set_callbacks(m_screen, &cbs, this);
    vterm_screen_set_damage_merge(m_screen, VTERM_DAMAGE_SCROLL);
    vterm_screen_enable_altscreen(m_screen, 1);
    VTermColor fg, bg; vterm_color_rgb(&fg, 0xe6, 0xe6, 0xea); vterm_color_rgb(&bg, 0x1a, 0x1a, 0x1e);
    vterm_state_set_default_colors(vterm_obtain_state(m_vt), &fg, &bg);
    vterm_screen_reset(m_screen, 1);

    struct winsize ws = {}; ws.ws_row = m_rows; ws.ws_col = m_cols;
    const pid_t pid = forkpty(&m_fd, nullptr, nullptr, &ws);
    if (pid < 0) { setState("error", QString("cannot open a terminal: ") + strerror(errno)); return; }
    if (pid == 0) {
        setenv("TERM", "xterm-256color", 1); setenv("COLORTERM", "truecolor", 1);
        if (!getenv("LANG")) setenv("LANG", "C.UTF-8", 1);
        signal(SIGPIPE, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGCHLD, SIG_DFL);
        QByteArray target = (username.isEmpty() ? host : username + "@" + host).toUtf8(), portS = QByteArray::number(m_port), key = keyFile.toUtf8();
        const QByteArray session = tmux.trimmed().toUtf8();
        const char *argv[24]; int n = 0;
        argv[n++] = "ssh"; argv[n++] = "-p"; argv[n++] = portS.constData();
        argv[n++] = "-o"; argv[n++] = "StrictHostKeyChecking=accept-new";       // first contact is trusted, a changed key still refused
        argv[n++] = "-o"; argv[n++] = "ServerAliveInterval=30";
        if (!key.isEmpty()) { argv[n++] = "-i"; argv[n++] = key.constData(); }
        if (!session.isEmpty()) argv[n++] = "-t";                                    // a tty for tmux
        argv[n++] = target.constData();
        if (!session.isEmpty()) { argv[n++] = "tmux"; argv[n++] = "new-session"; argv[n++] = "-A"; argv[n++] = "-s"; argv[n++] = session.constData(); }
        argv[n] = nullptr;
        execvp("ssh", const_cast<char *const *>(argv));
        const char *msg = "vncview: cannot run ssh (is the OpenSSH client installed?)\r\n";
        if (write(STDOUT_FILENO, msg, strlen(msg)) < 0) {}
        _exit(127);
    }
    m_pid = pid;
    m_notifier = new QSocketNotifier(m_fd, QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated, this, &SshSession::readPty);
    setState("connecting");
}

void SshSession::close()
{
    if (m_notifier) { delete m_notifier; m_notifier = nullptr; }
    if (m_fd >= 0) { ::close(m_fd); m_fd = -1; }
    if (m_pid > 0) {
        kill(m_pid, SIGHUP);
        int status = 0;
        for (int i = 0; i < 20 && waitpid(m_pid, &status, WNOHANG) == 0; ++i) usleep(20000);
        if (waitpid(m_pid, &status, WNOHANG) == 0) { kill(m_pid, SIGKILL); waitpid(m_pid, &status, 0); }
        m_pid = 0;
    }
    if (m_vt) { vterm_free(m_vt); m_vt = nullptr; m_screen = nullptr; }
    if (m_state != "error" && m_state != "idle") setState("closed");
}

void SshSession::readPty()
{
    char buf[65536];
    const ssize_t n = ::read(m_fd, buf, sizeof buf);
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
        ended(); return;                                          // EIO: the child closed its side
    }
    if (m_state == "connecting") {
        // ssh's own prompts arrive without a newline and leave the cursor after them; once the output settles
        // (m_settle) on something that is not a prompt, the remote shell is talking: connected. A saved password
        // answers the first password prompt; a second prompt (wrong password) is left to the user.
        m_recent.append(buf, int(n)); m_recent = m_recent.right(512);
        const QByteArray tail = m_recent.trimmed().toLower();
        if (!m_passwordSent && !m_password.isEmpty() && tail.endsWith("password:")) {
            m_passwordSent = true;
            const QByteArray line = m_password.toUtf8() + "\n";
            if (::write(m_fd, line.constData(), size_t(line.size())) < 0) {}
        }
        m_settle.start();
    }
    vterm_input_write(m_vt, buf, size_t(n));
    vterm_screen_flush_damage(m_screen);
    m_damaged = true;
    if (!m_flush.isActive()) m_flush.start();
}

void SshSession::ended()
{
    int status = 0;
    if (m_pid > 0 && waitpid(m_pid, &status, WNOHANG) <= 0) { usleep(50000); waitpid(m_pid, &status, WNOHANG); }
    const int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (m_notifier) { delete m_notifier; m_notifier = nullptr; }
    if (m_fd >= 0) { ::close(m_fd); m_fd = -1; }
    m_pid = 0;
    // the last screen lines carry ssh's reason (Permission denied, Connection refused, ...)
    QString last;
    if (m_screen) {
        for (int r = m_rows - 1; r >= 0 && last.isEmpty(); --r) {
            QString line;
            for (int c = 0; c < m_cols; ++c) { VTermScreenCell cell; vterm_screen_get_cell(m_screen, {r, c}, &cell); if (cell.chars[0] && cell.chars[0] != uint32_t(-1)) line += QString::fromUcs4(reinterpret_cast<const char32_t *>(&cell.chars[0]), 1); else if (!cell.chars[0]) line += ' '; }
            last = line.trimmed();
        }
    }
    if (m_state == "connecting") setState("error", last.isEmpty() ? QString("ssh exited with status %1").arg(code) : last);
    else setState("closed", code == 0 ? QString() : last);
}

void SshSession::resize(int rows, int cols)
{
    rows = qBound(2, rows, 500); cols = qBound(10, cols, 1000);
    if (rows == m_rows && cols == m_cols) return;
    m_rows = rows; m_cols = cols;
    if (m_vt) { vterm_set_size(m_vt, rows, cols); vterm_screen_flush_damage(m_screen); }
    if (m_fd >= 0) { struct winsize ws = {}; ws.ws_row = rows; ws.ws_col = cols; ioctl(m_fd, TIOCSWINSZ, &ws); }
    emit changed(); emit damaged();
}

void SshSession::sendText(const QString &text)
{
    if (m_fd < 0) return;
    const QByteArray b = text.toUtf8();
    if (::write(m_fd, b.constData(), size_t(b.size())) < 0) {}
}
void SshSession::sendKey(VTermKey key, VTermModifier mod) { if (m_vt) vterm_keyboard_key(m_vt, key, mod); }
void SshSession::sendChar(uint32_t c, VTermModifier mod) { if (m_vt) vterm_keyboard_unichar(m_vt, c, mod); }

bool SshSession::cellAt(int row, int col, VTermScreenCell &cell) const
{
    if (!m_screen) return false;
    if (row >= 0) return vterm_screen_get_cell(m_screen, {row, col}, &cell) != 0;
    const int i = m_scrollback.size() + row;                     // row -1 is the newest scrollback line
    if (i < 0 || i >= m_scrollback.size()) return false;
    const QVector<VTermScreenCell> &line = m_scrollback[i];
    if (col >= line.size()) { memset(&cell, 0, sizeof cell); cell.width = 1; return true; }
    cell = line[col]; return true;
}

// ---- libvterm callbacks --------------------------------------------------------------------------------------------
int SshSession::cbDamage(VTermRect, void *user) { auto *s = static_cast<SshSession *>(user); s->m_damaged = true; return 1; }
int SshSession::cbMoveCursor(VTermPos pos, VTermPos, int visible, void *user)
{
    auto *s = static_cast<SshSession *>(user);
    s->m_cursor = QPoint(pos.col, pos.row); s->m_cursorVisible = visible; s->m_damaged = true; return 1;
}
int SshSession::cbSetTermProp(VTermProp prop, VTermValue *val, void *user)
{
    auto *s = static_cast<SshSession *>(user);
    if (prop == VTERM_PROP_CURSORVISIBLE) { s->m_cursorVisible = val->boolean; s->m_damaged = true; }
    else if (prop == VTERM_PROP_TITLE) {
        if (val->string.initial) s->m_title.clear();
        s->m_title += QString::fromUtf8(val->string.str, int(val->string.len));
        if (val->string.final) emit s->changed();
    }
    return 1;
}
int SshSession::cbBell(void *user) { emit static_cast<SshSession *>(user)->bell(); return 1; }
int SshSession::cbPushLine(int cols, const VTermScreenCell *cells, void *user)
{
    auto *s = static_cast<SshSession *>(user);
    QVector<VTermScreenCell> line(cols);
    memcpy(line.data(), cells, sizeof(VTermScreenCell) * size_t(cols));
    s->m_scrollback.append(line);
    if (s->m_scrollback.size() > kScrollbackMax) s->m_scrollback.removeFirst();
    return 1;
}
int SshSession::cbPopLine(int cols, VTermScreenCell *cells, void *user)
{
    auto *s = static_cast<SshSession *>(user);
    if (s->m_scrollback.isEmpty()) return 0;
    const QVector<VTermScreenCell> line = s->m_scrollback.takeLast();
    for (int c = 0; c < cols; ++c) { if (c < line.size()) cells[c] = line[c]; else { memset(&cells[c], 0, sizeof(VTermScreenCell)); cells[c].width = 1; } }
    return 1;
}
void SshSession::cbOutput(const char *bytes, size_t len, void *user)
{
    auto *s = static_cast<SshSession *>(user);
    if (s->m_fd >= 0 && ::write(s->m_fd, bytes, len) < 0) {}
}
