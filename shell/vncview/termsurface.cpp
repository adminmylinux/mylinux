#include "termsurface.h"
#include <QPainter>
#include <QFontMetricsF>
#include <QKeyEvent>
#include <QWheelEvent>
#include <QGuiApplication>
#include <QClipboard>
#include <cmath>

TermSurface::TermSurface(QQuickItem *parent) : QQuickPaintedItem(parent)
{
    setAcceptedMouseButtons(Qt::AllButtons);
    setRenderTarget(QQuickPaintedItem::Image);
    setOpaquePainting(true);
    setFillColor(QColor(0x1a, 0x1a, 0x1e));
    m_font = QFont("DejaVu Sans Mono");
    setFontPt(11);
}

void TermSurface::setSession(SshSession *s)
{
    if (m_session == s) return;
    if (m_session) disconnect(m_session, nullptr, this, nullptr);
    m_session = s;
    if (s) {
        connect(s, &SshSession::damaged, this, [this] { if (m_scroll && m_session->scrollbackLines() < m_scroll) m_scroll = m_session->scrollbackLines(); update(); });
        connect(s, &SshSession::changed, this, [this] { update(); });
        relayout();
    }
    emit sessionChanged(); update();
}

void TermSurface::setFontPt(double pt)
{
    pt = qBound(5.0, pt, 40.0);
    m_fontPt = pt;
    m_font.setPointSizeF(pt);
    const QFontMetricsF fm(m_font);
    m_cellW = fm.horizontalAdvance(QLatin1Char('M')); m_cellH = std::ceil(fm.height()); m_ascent = fm.ascent();
    relayout(); emit changed(); update();
}

void TermSurface::setScroll(int lines)
{
    lines = qBound(0, lines, m_session ? m_session->scrollbackLines() : 0);
    if (lines == m_scroll) return;
    m_scroll = lines; emit changed(); update();
}

void TermSurface::relayout()
{
    if (!m_session || width() <= 0 || height() <= 0) return;
    m_session->resize(int(height() / m_cellH), int(width() / m_cellW));
}

void TermSurface::geometryChange(const QRectF &n, const QRectF &o)
{
    QQuickPaintedItem::geometryChange(n, o);
    if (n.size() != o.size()) relayout();
}

static QColor colorOf(VTermScreen *screen, VTermColor c, bool fg)
{
    if (fg ? VTERM_COLOR_IS_DEFAULT_FG(&c) : VTERM_COLOR_IS_DEFAULT_BG(&c)) return fg ? QColor(0xe6, 0xe6, 0xea) : QColor(0x1a, 0x1a, 0x1e);
    vterm_screen_convert_color_to_rgb(screen, &c);
    return QColor(c.rgb.red, c.rgb.green, c.rgb.blue);
}

void TermSurface::paint(QPainter *p)
{
    if (!m_session || !m_session->screen()) return;
    VTermScreen *screen = m_session->screen();
    const int rows = m_session->rows(), cols = m_session->cols();
    p->setFont(m_font);
    QFont bold = m_font; bold.setBold(true);
    QFont italic = m_font; italic.setItalic(true);
    for (int r = 0; r < rows; ++r) {
        const int srcRow = r - m_scroll;                        // negative rows come from the scrollback
        const qreal y = r * m_cellH;
        int c = 0;
        while (c < cols) {
            VTermScreenCell cell;
            if (!m_session->cellAt(srcRow, c, cell)) { ++c; continue; }
            if (cell.chars[0] == uint32_t(-1)) { ++c; continue; }   // the second half of a wide character
            // a run of cells with the same colours and attributes: one background rect, one text draw
            int end = c + 1;
            VTermScreenCell next;
            while (end < cols && m_session->cellAt(srcRow, end, next) && next.chars[0] != uint32_t(-1)
                   && memcmp(&next.fg, &cell.fg, sizeof cell.fg) == 0 && memcmp(&next.bg, &cell.bg, sizeof cell.bg) == 0
                   && next.attrs.bold == cell.attrs.bold && next.attrs.reverse == cell.attrs.reverse && next.attrs.underline == cell.attrs.underline
                   && next.attrs.italic == cell.attrs.italic && next.width == cell.width) ++end;
            QColor fg = colorOf(screen, cell.fg, true), bg = colorOf(screen, cell.bg, false);
            if (cell.attrs.reverse) std::swap(fg, bg);
            if (cell.attrs.bold && fg.lightness() < 200) fg = fg.lighter(130);
            const QRectF run(c * m_cellW, y, (end - c) * m_cellW * cell.width, m_cellH);
            p->fillRect(run, bg);
            QString text;
            for (int i = c; i < end; ++i) {
                VTermScreenCell cc; m_session->cellAt(srcRow, i, cc);
                if (!cc.chars[0]) { text += QLatin1Char(' '); continue; }
                for (int k = 0; k < VTERM_MAX_CHARS_PER_CELL && cc.chars[k]; ++k) text += QString::fromUcs4(reinterpret_cast<const char32_t *>(&cc.chars[k]), 1);
            }
            if (!text.trimmed().isEmpty()) {
                p->setFont(cell.attrs.bold ? bold : cell.attrs.italic ? italic : m_font);
                p->setPen(fg);
                if (cell.width == 2) { for (int i = 0; i < end - c; ++i) p->drawText(QPointF((c + i * 2) * m_cellW, y + m_ascent), text.mid(i, 1)); }
                else p->drawText(QPointF(c * m_cellW, y + m_ascent), text);
                if (cell.attrs.underline) p->fillRect(QRectF(run.x(), y + m_ascent + 2, run.width(), 1), fg);
            }
            c = end;
        }
    }
    // the cursor: a block on the live screen (not while scrolled back), inverted so the character stays readable
    if (m_session->cursorVisible() && m_scroll == 0 && hasActiveFocus()) {
        const QPoint cur = m_session->cursor();
        const QRectF cr(cur.x() * m_cellW, cur.y() * m_cellH, m_cellW, m_cellH);
        p->setCompositionMode(QPainter::RasterOp_SourceXorDestination);
        p->fillRect(cr, QColor(0xff, 0xff, 0xff));
        p->setCompositionMode(QPainter::CompositionMode_SourceOver);
    } else if (m_session->cursorVisible() && m_scroll == 0) {
        const QPoint cur = m_session->cursor();
        p->setPen(QColor(0xe6, 0xe6, 0xea)); p->drawRect(QRectF(cur.x() * m_cellW + 0.5, cur.y() * m_cellH + 0.5, m_cellW - 1, m_cellH - 1));
    }
}

void TermSurface::paste()
{
    if (!m_session) return;
    const QString t = QGuiApplication::clipboard()->text();
    if (!t.isEmpty()) { m_session->sendText(t); setScroll(0); }
}

void TermSurface::keyPressEvent(QKeyEvent *e)
{
    if (!m_session) { e->ignore(); return; }
    const Qt::KeyboardModifiers m = e->modifiers();
    int mod = VTERM_MOD_NONE;
    if (m & Qt::ShiftModifier) mod |= VTERM_MOD_SHIFT;
    if (m & Qt::ControlModifier) mod |= VTERM_MOD_CTRL;
    if (m & Qt::AltModifier) mod |= VTERM_MOD_ALT;
    // Ctrl+Shift+V pastes, Shift+PageUp/Down scroll the history
    if ((m & Qt::ControlModifier) && (m & Qt::ShiftModifier) && e->key() == Qt::Key_V) { paste(); e->accept(); return; }
    if ((m & Qt::ShiftModifier) && (e->key() == Qt::Key_PageUp || e->key() == Qt::Key_PageDown)) {
        setScroll(m_scroll + (e->key() == Qt::Key_PageUp ? 1 : -1) * qMax(1, m_session->rows() - 1)); e->accept(); return;
    }
    VTermKey key = VTERM_KEY_NONE;
    switch (e->key()) {
    case Qt::Key_Return: case Qt::Key_Enter: key = VTERM_KEY_ENTER; break;
    case Qt::Key_Tab: case Qt::Key_Backtab: key = VTERM_KEY_TAB; break;
    case Qt::Key_Backspace: key = VTERM_KEY_BACKSPACE; break;
    case Qt::Key_Escape: key = VTERM_KEY_ESCAPE; break;
    case Qt::Key_Up: key = VTERM_KEY_UP; break; case Qt::Key_Down: key = VTERM_KEY_DOWN; break;
    case Qt::Key_Left: key = VTERM_KEY_LEFT; break; case Qt::Key_Right: key = VTERM_KEY_RIGHT; break;
    case Qt::Key_Insert: key = VTERM_KEY_INS; break; case Qt::Key_Delete: key = VTERM_KEY_DEL; break;
    case Qt::Key_Home: key = VTERM_KEY_HOME; break; case Qt::Key_End: key = VTERM_KEY_END; break;
    case Qt::Key_PageUp: key = VTERM_KEY_PAGEUP; break; case Qt::Key_PageDown: key = VTERM_KEY_PAGEDOWN; break;
    default:
        if (e->key() >= Qt::Key_F1 && e->key() <= Qt::Key_F12) key = VTermKey(VTERM_KEY_FUNCTION(e->key() - Qt::Key_F1 + 1));
    }
    setScroll(0);
    if (key != VTERM_KEY_NONE) { m_session->sendKey(key, VTermModifier(mod)); e->accept(); return; }
    // Ctrl+letter: libvterm derives the control code from the plain letter; the event's text is empty or odd then
    if ((m & Qt::ControlModifier) && e->key() >= Qt::Key_A && e->key() <= Qt::Key_Z) {
        m_session->sendChar(uint32_t('a' + (e->key() - Qt::Key_A)), VTermModifier(mod & ~VTERM_MOD_SHIFT)); e->accept(); return;
    }
    const QString t = e->text();
    if (t.isEmpty()) { e->ignore(); return; }
    for (uint32_t u : t.toUcs4()) if (u >= 0x20 || u == 0x08 || u == 0x7f) m_session->sendChar(u, VTermModifier(mod & VTERM_MOD_ALT));
    e->accept();
}

void TermSurface::wheelEvent(QWheelEvent *e)
{
    const int lines = e->angleDelta().y() / 40;
    if (lines) setScroll(m_scroll + lines);
    e->accept();
}

void TermSurface::mousePressEvent(QMouseEvent *e)
{
    forceActiveFocus();
    if (e->button() == Qt::MiddleButton) paste();
    e->accept();
}
