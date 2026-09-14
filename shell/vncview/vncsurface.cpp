#include "vncsurface.h"
#include <QPainter>
#include <QMouseEvent>
#include <QHoverEvent>
#include <QWheelEvent>
#include <QKeyEvent>
#include <cmath>
#include <QDebug>
static const bool kDebug = qEnvironmentVariableIsSet("VNCVIEW_DEBUG");

VncSurface::VncSurface(QQuickItem *parent) : QQuickPaintedItem(parent)
{
    setAcceptedMouseButtons(Qt::AllButtons);
    setAcceptHoverEvents(true);
    setFlag(ItemAcceptsInputMethod, false);
    setRenderTarget(QQuickPaintedItem::Image);
    setOpaquePainting(true);
    setFillColor(Qt::black);
}

void VncSurface::setSession(VncSession *s)
{
    if (m_session == s) return;
    if (m_session) disconnect(m_session, nullptr, this, nullptr);
    m_session = s;
    if (s) {
        connect(s, &VncSession::damaged, this, [this](const QRect &r) {
            const QRectF t = target(); const QSize fb(m_session->fbWidth(), m_session->fbHeight());
            if (fb.isEmpty()) return;
            const qreal sx = t.width() / fb.width(), sy = t.height() / fb.height();
            update(QRect(int(std::floor(t.x() + r.x() * sx)) - 1, int(std::floor(t.y() + r.y() * sy)) - 1, int(std::ceil(r.width() * sx)) + 2, int(std::ceil(r.height() * sy)) + 2));
        });
        connect(s, &VncSession::resized, this, [this] { emit changed(); update(); });   // displayScale follows the remote's size
    }
    emit sessionChanged(); update();
}

QRectF VncSurface::target() const
{
    if (!m_session || m_session->fbWidth() <= 0) return boundingRect();
    const QSizeF fb(m_session->fbWidth(), m_session->fbHeight());
    if (!m_keepAspect) return boundingRect();
    QSizeF s = fb.scaled(size(), Qt::KeepAspectRatio) * m_zoom;
    // centred while it fits; once larger than the item, the pan fraction picks the visible part
    const qreal x = s.width() <= width() ? (width() - s.width()) / 2 : -(s.width() - width()) * m_pan.x();
    const qreal y = s.height() <= height() ? (height() - s.height()) / 2 : -(s.height() - height()) * m_pan.y();
    return QRectF(x, y, s.width(), s.height());
}

double VncSurface::displayScale() const
{
    if (!m_session || m_session->fbWidth() <= 0) return 1;
    return target().width() / m_session->fbWidth();
}

void VncSurface::setZoom(double z)
{
    z = qBound(0.25, z, 8.0);              // below 1 only through 1:1 on a remote smaller than the window
    if (qFuzzyCompare(z, m_zoom)) return;
    m_zoom = z; emit changed(); update();
}

void VncSurface::zoomStep(int dir)
{
    static const double steps[] = { 1, 1.25, 1.5, 2, 3, 4 };
    if (m_zoom < 1 - 1e-6) { setZoom(dir > 0 ? 1 : m_zoom); return; }
    int i = 0;
    for (int k = 0; k < 6; ++k) if (steps[k] <= m_zoom + 1e-6) i = k;
    i = qBound(0, i + dir, 5);
    setZoom(steps[i]);
}

void VncSurface::zoomToPixels()
{
    if (!m_session || m_session->fbWidth() <= 0 || width() <= 0) return;
    const QSizeF fit = QSizeF(m_session->fbWidth(), m_session->fbHeight()).scaled(size(), Qt::KeepAspectRatio);
    setZoom(m_session->fbWidth() / fit.width());
}

// the pointer's position as a fraction of the item, with a margin so the edges are reachable without pushing
// the pointer out of the window
void VncSurface::follow(const QPointF &p)
{
    if (m_zoom <= 1 || width() <= 0 || height() <= 0) return;
    const qreal m = 40;
    const QPointF pan(qBound(0.0, (p.x() - m) / qMax(1.0, width() - 2 * m), 1.0), qBound(0.0, (p.y() - m) / qMax(1.0, height() - 2 * m), 1.0));
    if ((pan - m_pan).manhattanLength() < 0.002) return;
    m_pan = pan; emit changed(); update();
}

void VncSurface::geometryChange(const QRectF &n, const QRectF &o)
{
    QQuickPaintedItem::geometryChange(n, o);
    if (n.size() != o.size()) emit changed();       // the fit, and so displayScale, depend on the item's size
}

void VncSurface::paint(QPainter *p)
{
    if (!m_session) return;
    const QImage img = m_session->frontImage();
    if (img.isNull()) return;
    const QRectF t = target();
    p->setRenderHint(QPainter::SmoothPixmapTransform, t.size() != QSizeF(img.size()));
    p->drawImage(t, img);
}

QPoint VncSurface::toRemote(const QPointF &p) const
{
    const QRectF t = target();
    if (!m_session || t.isEmpty()) return QPoint(0, 0);
    const int x = int((p.x() - t.x()) * m_session->fbWidth() / t.width()), y = int((p.y() - t.y()) * m_session->fbHeight() / t.height());
    return QPoint(qBound(0, x, m_session->fbWidth() - 1), qBound(0, y, m_session->fbHeight() - 1));
}

void VncSurface::pointer(const QPointF &p, int mask)
{
    if (!m_session) return;
    const QPoint r = toRemote(p);
    if (kDebug && mask) qInfo("vncview: pointer %d,%d mask %d", r.x(), r.y(), mask);
    m_session->sendPointer(r.x(), r.y(), mask);
}

static int rfbButton(Qt::MouseButton b)
{
    switch (b) { case Qt::LeftButton: return 1; case Qt::MiddleButton: return 2; case Qt::RightButton: return 4; case Qt::BackButton: return 128; case Qt::ForwardButton: return 256; default: return 0; }
}

void VncSurface::mousePressEvent(QMouseEvent *e) { forceActiveFocus(); m_mask |= rfbButton(e->button()); pointer(e->position(), m_mask); e->accept(); }
void VncSurface::mouseReleaseEvent(QMouseEvent *e) { m_mask &= ~rfbButton(e->button()); pointer(e->position(), m_mask); e->accept(); }
void VncSurface::mouseMoveEvent(QMouseEvent *e) { follow(e->position()); pointer(e->position(), m_mask); e->accept(); }
void VncSurface::hoverMoveEvent(QHoverEvent *e) { follow(e->position()); pointer(e->position(), m_mask); }
void VncSurface::wheelEvent(QWheelEvent *e)
{
    // one RFB wheel click per 120 units; buttons 4/5 vertical, 6/7 horizontal
    const QPoint d = e->angleDelta();
    auto click = [&](int button) { pointer(e->position(), m_mask | button); pointer(e->position(), m_mask); };
    for (int i = 0; i < std::abs(d.y()) / 120; ++i) click(d.y() > 0 ? 8 : 16);
    for (int i = 0; i < std::abs(d.x()) / 120; ++i) click(d.x() > 0 ? 32 : 64);
    e->accept();
}

quint32 VncSurface::keysymFor(QKeyEvent *e) const
{
    if (e->nativeVirtualKey()) return e->nativeVirtualKey();           // xkb keysym from the Wayland platform
    switch (e->key()) {                                                   // fallbacks for other platforms
    case Qt::Key_Return: return 0xff0d; case Qt::Key_Enter: return 0xff8d; case Qt::Key_Backspace: return 0xff08; case Qt::Key_Tab: return 0xff09;
    case Qt::Key_Escape: return 0xff1b; case Qt::Key_Delete: return 0xffff; case Qt::Key_Left: return 0xff51; case Qt::Key_Up: return 0xff52;
    case Qt::Key_Right: return 0xff53; case Qt::Key_Down: return 0xff54; case Qt::Key_Shift: return 0xffe1; case Qt::Key_Control: return 0xffe3;
    case Qt::Key_Alt: return 0xffe9; case Qt::Key_Meta: case Qt::Key_Super_L: return 0xffeb; case Qt::Key_Super_R: return 0xffec;
    default: break;
    }
    const QString t = e->text();
    if (t.size() == 1 && t.at(0).unicode() >= 0x20) { const ushort u = t.at(0).unicode(); return u < 0x100 ? u : 0x01000000 + u; }
    return 0;
}

void VncSurface::keyPressEvent(QKeyEvent *e)
{
    if (!m_session) return;
    const quint32 k = keysymFor(e);
    if (!k) { e->ignore(); return; }
    m_downKeys.insert(k);
    if (kDebug) qInfo("vncview: key 0x%x down (qt 0x%x, native %u, text '%s')", k, e->key(), e->nativeVirtualKey(), qPrintable(e->text()));
    m_session->sendKey(k, true); e->accept();
}

void VncSurface::keyReleaseEvent(QKeyEvent *e)
{
    if (!m_session) return;
    const quint32 k = keysymFor(e);
    if (!k) { e->ignore(); return; }
    m_downKeys.remove(k);
    m_session->sendKey(k, false); e->accept();
}

void VncSurface::focusOutEvent(QFocusEvent *)
{
    // keys held while focus leaves (a shell shortcut, a tab switch) must not stay pressed on the remote
    if (!m_session) return;
    for (quint32 k : m_downKeys) m_session->sendKey(k, false);
    m_downKeys.clear();
    if (m_mask) { m_mask = 0; }
}
