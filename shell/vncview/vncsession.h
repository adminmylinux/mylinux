#pragma once
#include <QObject>
#include <QQmlEngine>
#include <QImage>
#include <QMutex>
#include <QThread>
#include <QRect>
#include <QVector>
#include <QString>
#include <atomic>

struct _rfbClient;

// One VNC connection: libvncclient runs in its own thread (the library is not thread safe), input events are
// queued to that thread, framebuffer updates land in `front` (a copy of the damaged rectangles, so painting
// never reads a buffer the decoder is writing) and are announced with damaged().
class VncSession : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString host READ host NOTIFY changed)
    Q_PROPERTY(int port READ port NOTIFY changed)
    Q_PROPERTY(QString state READ state NOTIFY changed)        // idle | connecting | connected | closed | error | untrusted
    Q_PROPERTY(QString error READ error NOTIFY changed)
    // state "untrusted": the server's TLS certificate is not pinned yet (or differs from the pinned one)
    Q_PROPERTY(QString certFingerprint READ certFingerprint NOTIFY changed)
    Q_PROPERTY(QString certName READ certName NOTIFY changed)
    Q_PROPERTY(bool certChanged READ certChanged NOTIFY changed)
    Q_PROPERTY(int fbWidth READ fbWidth NOTIFY changed)
    Q_PROPERTY(int fbHeight READ fbHeight NOTIFY changed)
    Q_PROPERTY(QString quality READ quality WRITE setQuality NOTIFY changed)   // fast | balanced | best
    Q_PROPERTY(QString serverText READ serverText NOTIFY changed)              // last clipboard text from the server
    Q_PROPERTY(qint64 updates READ updates NOTIFY changed)
public:
    explicit VncSession(QObject *parent = nullptr);
    ~VncSession() override;
    QString host() const { return m_host; }
    int port() const { return m_port; }
    QString state() const { return m_state; }
    QString error() const { return m_error; }
    QString certFingerprint() const { return m_certFingerprint; }
    QString certName() const { return m_certName; }
    bool certChanged() const { return m_certChanged; }
    int fbWidth() const { return m_front.width(); }
    int fbHeight() const { return m_front.height(); }
    QString quality() const { return m_quality; }
    void setQuality(const QString &q);
    QString serverText() const { return m_serverText; }
    qint64 updates() const { return m_updates; }
    Q_INVOKABLE void open(const QString &host, int port, const QString &username, const QString &password);
    Q_INVOKABLE void close();
    Q_INVOKABLE void trustCertificate();                         // pin the offered certificate and connect again
    Q_INVOKABLE void sendKey(quint32 keysym, bool down);
    Q_INVOKABLE void sendPointer(int x, int y, int buttonMask);
    Q_INVOKABLE void sendText(const QString &text);            // to the server's clipboard
    // painting side
    QImage frontImage() const;                                   // shallow copy under the lock (implicit sharing)
    QMutex &frontLock() { return m_lock; }
signals:
    void changed();
    void damaged(const QRect &r);
    void resized(int w, int h);
private:
    friend class VncThread;
    void setState(const QString &s, const QString &err = QString());
    QString m_host, m_username, m_password, m_state = "idle", m_error, m_quality = "balanced", m_serverText;
    QByteArray m_certPem;
    QString m_certFingerprint, m_certName;
    bool m_certChanged = false;
    int m_port = 5900;
    QImage m_front;
    mutable QMutex m_lock;
    QThread *m_thread = nullptr;
    qint64 m_updates = 0;
};
