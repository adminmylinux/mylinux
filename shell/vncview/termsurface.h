#pragma once
#include <QQuickPaintedItem>
#include <QQmlEngine>
#include <QPointer>
#include <QFont>
#include "sshsession.h"

// Draws an SshSession's screen as a grid of cells in a monospace font and turns keys, paste and the wheel into
// terminal input. fontPt sizes the text; the grid follows the item's size (the session is told the new rows/cols).
class TermSurface : public QQuickPaintedItem
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(SshSession *session READ session WRITE setSession NOTIFY sessionChanged)
    Q_PROPERTY(double fontPt READ fontPt WRITE setFontPt NOTIFY changed)
    Q_PROPERTY(int scroll READ scroll WRITE setScroll NOTIFY changed)      // lines scrolled back into history
public:
    explicit TermSurface(QQuickItem *parent = nullptr);
    SshSession *session() const { return m_session; }
    void setSession(SshSession *s);
    double fontPt() const { return m_fontPt; }
    void setFontPt(double pt);
    int scroll() const { return m_scroll; }
    void setScroll(int lines);
    Q_INVOKABLE void paste();
    void paint(QPainter *p) override;
signals:
    void sessionChanged();
    void changed();
protected:
    void keyPressEvent(QKeyEvent *e) override;
    void wheelEvent(QWheelEvent *e) override;
    void mousePressEvent(QMouseEvent *e) override;
    void geometryChange(const QRectF &n, const QRectF &o) override;
private:
    void relayout();
    QPointer<SshSession> m_session;
    QFont m_font;
    double m_fontPt = 11;
    qreal m_cellW = 8, m_cellH = 16, m_ascent = 12;
    int m_scroll = 0;
};
