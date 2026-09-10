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

    // Minimum size of a window as a tile (frame pixels): the client's xdg min size, never below a floor
    // that keeps a terminal usable. A subtree's minimum adds its children along the split.
    readonly property int floorW: 160
    readonly property int floorH: 100
    function minOf(win) {
        const s = win && win.toplevel ? win.toplevel.minSize : Qt.size(0, 0), k = win ? win.surfaceScale : 1
        return { w: Math.max(floorW, s.width > 0 ? s.width * k : 0), h: Math.max(floorH, (s.height > 0 ? s.height * k : 0) + (win ? win.titleHeight : 0)) }
    }
    function minSize(n) {
        if (!n) return { w: 0, h: 0 }
        if (isLeaf(n)) return minOf(n.win)
        const a = minSize(n.a), b = minSize(n.b)
        return n.split === "h" ? { w: a.w + gap + b.w, h: Math.max(a.h, b.h) } : { w: Math.max(a.w, b.w), h: a.h + gap + b.h }
    }
    function fits(n, r) { const m = minSize(n); return m.w <= r.width && m.h <= r.height }
    // insert next to `focus` (or at the root), splitting along the longer side of that leaf's rect.
    // Returns false (window left floating) when no split direction leaves both windows their minimum size.
    function add(win, focus) {
        const leaf = { win: win, rect: null }
        if (!root) { win.tiled = true; root = leaf; relayout(); return true }
        let target = focus ? findLeaf(root, focus) : null
        if (!target) { const l = leaves(root); target = l[l.length - 1] }
        const r = target.rect || Qt.rect(gap, gap, area.width - 2 * gap, area.height - 2 * gap)
        const split = { split: r.width >= r.height ? "h" : "v", ratio: 0.5, a: target, b: leaf, rect: null }
        if (!fits(split, r)) { split.split = split.split === "h" ? "v" : "h"; if (!fits(split, r)) return false }
        win.tiled = true
        const p = parentOf(root, target, null)
        if (!p) root = split; else if (p.a === target) p.a = split; else p.b = split
        relayout()
        return true
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
    // The split point follows the ratio, then bends to give each side at least its minimum, and never
    // leaves either side a negative size (a tiny work area gives tiny tiles, never overlapping ones).
    function layoutNode(n, r) {
        n.rect = r
        if (isLeaf(n)) { if (n.win) n.win.setTileRect(r); return }
        const g = gap, ma = minSize(n.a), mb = minSize(n.b)
        if (n.split === "h") {
            const total = Math.max(0, r.width - g)
            let w = Math.round(total * n.ratio)
            w = Math.max(ma.w, Math.min(w, total - mb.w))
            w = Math.max(0, Math.min(w, total))
            layoutNode(n.a, Qt.rect(r.x, r.y, w, r.height)); layoutNode(n.b, Qt.rect(r.x + w + g, r.y, total - w, r.height))
        } else {
            const total = Math.max(0, r.height - g)
            let h = Math.round(total * n.ratio)
            h = Math.max(ma.h, Math.min(h, total - mb.h))
            h = Math.max(0, Math.min(h, total))
            layoutNode(n.a, Qt.rect(r.x, r.y, r.width, h)); layoutNode(n.b, Qt.rect(r.x, r.y + h + g, r.width, total - h))
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
        const flipped = p.split === "h" ? "v" : "h"
        if (p.rect && !fits({ split: flipped, a: p.a, b: p.b }, p.rect)) return   // would violate a minimum size
        p.split = flipped; relayout()
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
