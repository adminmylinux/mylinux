#include "vncsession.h"
#include <rfb/rfbclient.h>
#include <QDebug>
#include <QMetaObject>
#include <QElapsedTimer>
#include <cstring>
#include <cstdlib>

// ---- the client thread ------------------------------------------------------------------------
struct QueuedEvent { enum { Key, Pointer, Text } kind; quint32 keysym = 0; bool down = false; int x = 0, y = 0, mask = 0; QByteArray text; };

class VncThread : public QThread
{
public:
    VncThread(VncSession *s) : session(s) {}
    VncSession *session;
    rfbClient *client = nullptr;
    QMutex qlock; QVector<QueuedEvent> queue;
    std::atomic<bool> quit{false};
    QImage back;                       // the decoder's buffer (client->frameBuffer points into it)
    QRect pending;                     // damage accumulated in the current frame

    static VncThread *self(rfbClient *c) { return static_cast<VncThread *>(rfbClientGetClientData(c, (void *)"vt")); }

    static rfbBool mallocFb(rfbClient *c) {
        VncThread *t = self(c);
        t->back = QImage(c->width, c->height, QImage::Format_RGB32);
        t->back.fill(Qt::black);
        c->frameBuffer = t->back.bits();
        c->format.bitsPerPixel = 32; c->format.depth = 24; c->format.trueColour = TRUE; c->format.bigEndian = FALSE;
        c->format.redShift = 16; c->format.greenShift = 8; c->format.blueShift = 0;
        c->format.redMax = c->format.greenMax = c->format.blueMax = 255;
        SetFormatAndEncodings(c);
        {
            QMutexLocker l(&t->session->m_lock);
            t->session->m_front = QImage(c->width, c->height, QImage::Format_RGB32);
            t->session->m_front.fill(Qt::black);
        }
        QMetaObject::invokeMethod(t->session, [s = t->session, w = c->width, h = c->height] { emit s->resized(w, h); emit s->changed(); }, Qt::QueuedConnection);
        return TRUE;
    }
    static void gotUpdate(rfbClient *c, int x, int y, int w, int h) {
        VncThread *t = self(c);
        t->pending = t->pending.united(QRect(x, y, w, h));
    }
    static void finishedUpdate(rfbClient *c) {
        VncThread *t = self(c);
        if (t->pending.isEmpty()) return;
        const QRect r = t->pending.intersected(t->back.rect()); t->pending = QRect();
        if (r.isEmpty()) return;
        {
            QMutexLocker l(&t->session->m_lock);
            QImage &f = t->session->m_front;
            if (f.size() != t->back.size()) return;
            const int bpl = f.bytesPerLine();
            for (int yy = r.top(); yy <= r.bottom(); ++yy)
                memcpy(f.scanLine(yy) + r.left() * 4, t->back.constScanLine(yy) + r.left() * 4, size_t(r.width()) * 4);
            (void)bpl;
        }
        t->session->m_updates++;
        QMetaObject::invokeMethod(t->session, [s = t->session, r] { emit s->damaged(r); }, Qt::QueuedConnection);
    }
    static char *getPassword(rfbClient *c) { return strdup(self(c)->session->m_password.toUtf8().constData()); }
    static rfbCredential *getCredential(rfbClient *c, int type) {
        VncThread *t = self(c);
        if (type != rfbCredentialTypeUser) return nullptr;
        auto *cred = (rfbCredential *)calloc(1, sizeof(rfbCredential));
        cred->userCredential.username = strdup(t->session->m_username.toUtf8().constData());
        cred->userCredential.password = strdup(t->session->m_password.toUtf8().constData());
        return cred;
    }
    static void gotCutText(rfbClient *c, const char *text, int len) {
        VncThread *t = self(c);
        const QString s = QString::fromLatin1(text, len);
        QMetaObject::invokeMethod(t->session, [s2 = t->session, s] { s2->m_serverText = s; emit s2->changed(); }, Qt::QueuedConnection);
    }
    static void logIt(const char *fmt, ...) { va_list a; va_start(a, fmt); char b[512]; vsnprintf(b, sizeof b, fmt, a); va_end(a); qInfo("vnc: %s", QByteArray(b).trimmed().constData()); }

    void run() override {
        client = rfbGetClient(8, 3, 4);
        rfbClientSetClientData(client, (void *)"vt", this);
        client->MallocFrameBuffer = mallocFb;
        client->GotFrameBufferUpdate = gotUpdate;
        client->FinishedFrameBufferUpdate = finishedUpdate;
        client->GetPassword = getPassword;
        client->GetCredential = getCredential;
        client->GotXCutText = gotCutText;
        client->canHandleNewFBSize = TRUE;
        client->serverHost = strdup(session->m_host.toUtf8().constData());
        client->serverPort = session->m_port;
        // encodings: Tight (JPEG for photos, zlib for the rest) first, ZRLE second; "fast" trades quality for bytes
        const QString q = session->m_quality;
        client->appData.encodingsString = "tight zrle copyrect hextile zlib raw";
        client->appData.enableJPEG = TRUE;
        client->appData.qualityLevel = q == "fast" ? 4 : q == "best" ? 9 : 7;
        client->appData.compressLevel = q == "fast" ? 2 : q == "best" ? 6 : 3;
        client->appData.useRemoteCursor = FALSE;      // the server draws the pointer into the frame
        rfbClientLog = logIt; rfbClientErr = logIt;
        static const uint32_t schemes[] = { rfbVeNCrypt, rfbVncAuth, rfbNoAuth, rfbARD, 0 };
        SetClientAuthSchemes(client, schemes, -1);
        if (!rfbInitClient(client, nullptr, nullptr)) {         // frees the client on failure
            client = nullptr;
            QMetaObject::invokeMethod(session, [s = session] { s->setState("error", "could not connect (see the shell log for the reason)"); }, Qt::QueuedConnection);
            return;
        }
        QMetaObject::invokeMethod(session, [s = session] { s->setState("connected"); }, Qt::QueuedConnection);
        while (!quit) {
            // short waits: queued input goes out within a few ms even when the server is silent
            const int r = WaitForMessage(client, 5000);
            if (r < 0) break;
            if (r > 0 && !HandleRFBServerMessage(client)) break;
            QVector<QueuedEvent> ev;
            { QMutexLocker l(&qlock); ev.swap(queue); }
            for (const QueuedEvent &e : ev) {
                if (e.kind == QueuedEvent::Key) { if (!SendKeyEvent(client, e.keysym, e.down ? TRUE : FALSE)) qWarning("vncview: SendKeyEvent failed"); }
                else if (e.kind == QueuedEvent::Pointer) SendPointerEvent(client, e.x, e.y, e.mask);
                else SendClientCutText(client, const_cast<char *>(e.text.constData()), e.text.size());
            }
        }
        client->frameBuffer = nullptr;                          // ours (the QImage owns it)
        rfbClientCleanup(client); client = nullptr;
        QMetaObject::invokeMethod(session, [s = session, q = quit.load()] { s->setState(q ? "closed" : "error", q ? QString() : "connection lost"); }, Qt::QueuedConnection);
    }
    void post(const QueuedEvent &e) { QMutexLocker l(&qlock); queue.append(e); }
};

// ---- the session ---------------------------------------------------------------------------------
VncSession::VncSession(QObject *parent) : QObject(parent) {}
VncSession::~VncSession() { close(); }

void VncSession::setQuality(const QString &q) { if (q == m_quality) return; m_quality = q; emit changed(); }

void VncSession::setState(const QString &s, const QString &err)
{
    m_state = s; m_error = err; emit changed();
}

void VncSession::open(const QString &host, int port, const QString &username, const QString &password)
{
    close();
    m_host = host; m_port = port > 0 ? port : 5900; m_username = username; m_password = password;
    setState("connecting");
    auto *t = new VncThread(this);
    m_thread = t;
    t->start();
}

void VncSession::close()
{
    if (!m_thread) return;
    auto *t = static_cast<VncThread *>(m_thread);
    t->quit = true;
    t->wait(6000);
    if (t->isRunning()) { t->terminate(); t->wait(1000); }
    delete t; m_thread = nullptr;
    if (m_state != "error") setState("closed");
}

void VncSession::sendKey(quint32 keysym, bool down)
{
    if (!m_thread || m_state != "connected") return;
    QueuedEvent e; e.kind = QueuedEvent::Key; e.keysym = keysym; e.down = down;
    static_cast<VncThread *>(m_thread)->post(e);
}

void VncSession::sendPointer(int x, int y, int buttonMask)
{
    if (!m_thread || m_state != "connected") return;
    QueuedEvent e; e.kind = QueuedEvent::Pointer; e.x = x; e.y = y; e.mask = buttonMask;
    static_cast<VncThread *>(m_thread)->post(e);
}

void VncSession::sendText(const QString &text)
{
    if (!m_thread || m_state != "connected") return;
    QueuedEvent e; e.kind = QueuedEvent::Text; e.text = text.toLatin1();
    static_cast<VncThread *>(m_thread)->post(e);
}

QImage VncSession::frontImage() const { QMutexLocker l(&m_lock); return m_front; }
