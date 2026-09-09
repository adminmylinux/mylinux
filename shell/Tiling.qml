import QtQuick

// Dwindle tiling (Hyprland-style): a binary tree of splits over the work area. Windows that are
// tiled get their rect assigned here; floating windows are left alone.
QtObject {
    id: tiling
    property Item area                 // the window layer
    property bool enabled: true
    property int gap: 10
    property var root: null            // { win } | { split: "h"|"v", ratio, a, b }
    property int revision: 0

    function isLeaf(n) { return n && n.win !== undefined }
    function leaves(n, out) { if (!n) return out || []; out = out || []; if (isLeaf(n)) out.push(n); else { leaves(n.a, out); leaves(n.b, out) } return out }
    function findLeaf(n, win) { if (!n) return null; if (isLeaf(n)) return n.win === win ? n : null; return findLeaf(n.a, win) || findLeaf(n.b, win) }
    function parentOf(n, target, parent) { if (!n || isLeaf(n)) return n === target ? parent : null; if (n === target) return parent; return parentOf(n.a, target, n) || parentOf(n.b, target, n) }

    // insert next to `focus` (or at the root), splitting along the longer side of that leaf's rect
    function add(win, focus) {
        const leaf = { win: win, rect: null }
        win.tiled = true
        if (!root) { root = leaf; relayout(); return }
        let target = focus ? findLeaf(root, focus) : null
        if (!target) { const l = leaves(root); target = l[l.length - 1] }
        const r = target.rect || Qt.rect(0, 0, area.width, area.height)
        const split = { split: r.width >= r.height ? "h" : "v", ratio: 0.5, a: null, b: null, rect: null }
        const p = parentOf(root, target, null)
        split.a = target; split.b = leaf
        if (!p) root = split; else if (p.a === target) p.a = split; else p.b = split
        relayout()
    }
    function remove(win) {
        const leaf = findLeaf(root, win); if (!leaf) return
        win.tiled = false
        const p = parentOf(root, leaf, null)
        if (!p) { root = null; revision++; return }
        const sibling = p.a === leaf ? p.b : p.a
        const gp = parentOf(root, p, null)
        if (!gp) root = sibling; else if (gp.a === p) gp.a = sibling; else gp.b = sibling
        relayout()
    }
    function layoutNode(n, r) {
        n.rect = r
        if (isLeaf(n)) { if (n.win) n.win.setTileRect(r); return }
        const g = gap
        if (n.split === "h") {
            const w = Math.round((r.width - g) * n.ratio)
            layoutNode(n.a, Qt.rect(r.x, r.y, w, r.height)); layoutNode(n.b, Qt.rect(r.x + w + g, r.y, r.width - w - g, r.height))
        } else {
            const h = Math.round((r.height - g) * n.ratio)
            layoutNode(n.a, Qt.rect(r.x, r.y, r.width, h)); layoutNode(n.b, Qt.rect(r.x, r.y + h + g, r.width, r.height - h - g))
        }
    }
    function relayout() {
        if (!root || !area) { revision++; return }
        layoutNode(root, Qt.rect(gap, gap, area.width - 2 * gap, area.height - 2 * gap)); revision++
    }
    // neighbour in a direction, by rect centres
    function neighbour(win, dir) {
        const me = findLeaf(root, win); if (!me || !me.rect) return null
        const cx = me.rect.x + me.rect.width / 2, cy = me.rect.y + me.rect.height / 2
        let best = null, bestD = 1e9
        for (const l of leaves(root)) {
            if (l === me || !l.rect) continue
            const lx = l.rect.x + l.rect.width / 2, ly = l.rect.y + l.rect.height / 2
            const dx = lx - cx, dy = ly - cy
            const ok = dir === "left" ? dx < -1 && Math.abs(dy) <= Math.abs(dx) + l.rect.height / 2
                     : dir === "right" ? dx > 1 && Math.abs(dy) <= Math.abs(dx) + l.rect.height / 2
                     : dir === "up" ? dy < -1 && Math.abs(dx) <= Math.abs(dy) + l.rect.width / 2
                     : dy > 1 && Math.abs(dx) <= Math.abs(dy) + l.rect.width / 2
            if (!ok) continue
            const d = dx * dx + dy * dy
            if (d < bestD) { bestD = d; best = l }
        }
        return best ? best.win : null
    }
    function swap(win, dir) {
        const other = neighbour(win, dir); if (!other) return
        const a = findLeaf(root, win), b = findLeaf(root, other)
        a.win = other; b.win = win; relayout()
    }
    // flip the split that holds the focused window (Omarchy ⌘J)
    function toggleSplit(win) {
        const leaf = findLeaf(root, win); if (!leaf) return
        const p = parentOf(root, leaf, null); if (!p) return
        p.split = p.split === "h" ? "v" : "h"; relayout()
    }
    // grow the focused window's share of its parent split
    function resize(win, dir) {
        const leaf = findLeaf(root, win); if (!leaf) return
        let node = leaf, p = parentOf(root, node, null)
        const wantH = dir === "left" || dir === "right"
        while (p && ((p.split === "h") !== wantH)) { node = p; p = parentOf(root, node, null) }
        if (!p) return
        const grow = (dir === "right" || dir === "down") === (p.a === node)
        p.ratio = Math.max(0.15, Math.min(0.85, p.ratio + (grow ? 0.05 : -0.05))); relayout()
    }
}
