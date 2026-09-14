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
    // zoom 1 = the framebuffer fitted into the item; larger magnifies, and the view follows the pointer
    // (the pointer at the right edge shows the right part), so clicks still land where they are made
    Q_PROPERTY(double zoom READ zoom WRITE setZoom NOTIFY changed)
    Q_PROPERTY(double displayScale READ displayScale NOTIFY changed)     // item pixels per remote pixel
public:
    explicit VncSurface(QQuickItem *parent = nullptr);
    VncSession *session() const { return m_session; }
    void setSession(VncSession *s);
    bool keepAspect() const { return m_keepAspect; }
    void setKeepAspect(bool k) { m_keepAspect = k; emit changed(); update(); }
    double zoom() const { return m_zoom; }
    void setZoom(double z);
    double displayScale() const;
    Q_INVOKABLE void zoomStep(int dir);            // ±1: the next of 1, 1.25, 1.5, 2, 3, 4 (below 1 = fit)
    Q_INVOKABLE void zoomToPixels();               // one remote pixel per item pixel
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
    void geometryChange(const QRectF &n, const QRectF &o) override;
private:
    QRectF target() const;                          // where the framebuffer lands inside the item
    QPoint toRemote(const QPointF &p) const;
    void pointer(const QPointF &p, int mask);
    quint32 keysymFor(QKeyEvent *e) const;
    QPointer<VncSession> m_session;
    bool m_keepAspect = true;
    double m_zoom = 1;
    QPointF m_pan = QPointF(0.5, 0.5);             // which part is shown when zoomed: 0 = left/top edge, 1 = right/bottom
    void follow(const QPointF &p);
    int m_mask = 0;
    QSet<quint32> m_downKeys;
};
