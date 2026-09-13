#pragma once
#include <QQuickItem>
#include <QQuickPaintedItem>
#include <QSet>
#include <QQmlEngine>
#include <QPointer>
#include "vncsession.h"

// Paints a session's framebuffer scaled to its own size and turns mouse and key events into RFB events.
// Keys: on Wayland Qt hands us the xkb keysym as nativeVirtualKey(), which is exactly what RFB wants.
class VncSurface : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(VncSession *session READ session WRITE setSession NOTIFY sessionChanged)
    Q_PROPERTY(bool keepAspect READ keepAspect WRITE setKeepAspect NOTIFY changed)
public:
    explicit VncSurface(QQuickItem *parent = nullptr);
    VncSession *session() const { return m_session; }
    void setSession(VncSession *s);
    bool keepAspect() const { return m_keepAspect; }
    void setKeepAspect(bool k) { m_keepAspect = k; emit changed(); update(); }
    void paint(QPainter *p) override;
signals:
    void sessionChanged();
    void changed();
protected:
    void mousePressEvent(QMouseEvent *e) override;
    void mouseReleaseEvent(QMouseEvent *e) override;
    void mouseMoveEvent(QMouseEvent *e) override;
    void hoverMoveEvent(QHoverEvent *e) override;
    void wheelEvent(QWheelEvent *e) override;
    void keyPressEvent(QKeyEvent *e) override;
    void keyReleaseEvent(QKeyEvent *e) override;
    void focusOutEvent(QFocusEvent *e) override;
private:
    QRectF target() const;                          // where the framebuffer lands inside the item
    QPoint toRemote(const QPointF &p) const;
    void pointer(const QPointF &p, int mask);
    quint32 keysymFor(QKeyEvent *e) const;
    QPointer<VncSession> m_session;
    bool m_keepAspect = true;
    int m_mask = 0;
    QSet<quint32> m_downKeys;
};
