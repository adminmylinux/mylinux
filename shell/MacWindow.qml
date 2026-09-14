import QtQuick
import QtWayland.Compositor
import QtWayland.Compositor.XdgShell

// A macOS-style frame around one Wayland toplevel surface.
Item {
    id: win
    property var toplevel
    property var shellSurface
    property var output              // the Desktop window
    property int cascadeIndex: 0
    property string title: toplevel ? (toplevel.title || toplevel.appId || "Window") : ""
    // Apps that draw their own decoration (GTK header bars, Chromium in CSD mode) get no second title bar
    // from us. Recognised by the shadow margins they keep around the window geometry; the xdg-decoration
    // mode is no use here, because foot (configured without any decoration) also reports client-side.
    readonly property bool selfDecorated: shellSurface && surfaceItem.width > 0 && shellSurface.windowGeometry.width > 0
            && (shellSurface.windowGeometry.width < surfaceItem.width - 2 || shellSurface.windowGeometry.height < surfaceItem.height - 2)
    readonly property bool showTitle: !helper && !fullscreen && (Theme.titleBars === "always" || (Theme.titleBars === "auto" && !selfDecorated))
    readonly property int titleHeight: showTitle ? Theme.px(34) : 0
    onTitleHeightChanged: if (tiled && output && output.tilings) output.tilingOf(win).relayout()   // re-send the tile size
    readonly property int radius: Theme.px(12)
    // fractional UI scale is applied to the client surface as an item scale; integer scale is HiDPI in the client.
    // Terminals are the exception: foot draws its text at size × scale itself (Theme.terminalRenderPt), which stays
    // sharp where a scaled-down bitmap smears thin glyphs.
    readonly property bool isTerminal: !!toplevel && toplevel.appId === "foot"
    readonly property real surfaceScale: isTerminal ? 1 : Theme.scale / Theme.outputScale
    onIsTerminalChanged: reconfigure()
    property bool minimized: false
    property int workspace: 1
    property bool scratch: false          // lives on the scratchpad (⌘S shows/hides it over any workspace)
    property bool added: false            // tiled/raised by the desktop once the app id is known (see Desktop.finishAdd)
    property bool helper: false           // a nameless 1x1 helper surface (wl-clipboard): kept invisible, never tiled
    readonly property bool mapped: surfaceItem.width > 0 && surfaceItem.height > 0
    // Keyboard focus only goes to a surface that has content: GTK (Firefox) ignores a focus-enter it gets
    // before its window is mapped and then drops every key, because no second enter ever comes.
    onMappedChanged: if (mapped && output) { if (!added) output.windowMapped(win); if (output.focusedWindow === win) refocus(); reconfigure() }
    // raise() defers the seat focus until the first buffer, so this is the first enter the client sees
    function refocus() { surfaceItem.takeFocus(); if (output) output.focusedWindow = win }
    // Client requests go through the same state model as the shell's own shortcuts. A tiled window's
    // maximize request is answered with its tile (no MaximizedState), so the client learns it was refused.
    Connections { target: win.toplevel
        function onAppIdChanged() { if (win.toplevel.appId && win.output && !win.added) win.output.finishAdd(win) }
        function onSetFullscreen(o) { win.setFullscreen(true) }
        function onUnsetFullscreen() { win.setFullscreen(false) }
        function onSetMaximized() { if (win.tiled || win.fullscreen) win.reconfigure(); else win.zoom() }
        function onUnsetMaximized() { win.unzoom() }
        function onSetMinimized() { win.minimize() }
    }
    // the work area (window layer) changed size: fullscreen and zoomed windows follow it
    Connections { target: win.parent
        function onWidthChanged() { if (win.fullscreen) win.applyFullscreen(); else if (win.zoomed) win.applyZoom() }
        function onHeightChanged() { if (win.fullscreen) win.applyFullscreen(); else if (win.zoomed) win.applyZoom() }
    }
    function takeKeyboardFocus() { surfaceItem.takeFocus() }
    // (not "onWorkspace": names starting with "on" + a capital read as signal handlers in QML)
    readonly property bool shownWorkspace: !output || (scratch ? output.scratchVisible : output.workspace === workspace)
    property bool placed: false
    property bool tiled: false
    // ---- window state: every xdg configure is built here from the window's role ----
    // fullscreen: covers the work area, no title bar, taken out of the tiling tree (re-added on exit).
    // zoomed: maximized to the work area (green button, title double-click, client set_maximized).
    // Only the focused window is sent ActivatedState; losing focus re-sends the same size without it.
    property bool fullscreen: false
    property bool zoomed: false
    property rect savedGeo: Qt.rect(0, 0, 0, 0)      // floating geometry before fullscreen / zoom (surface units)
    property bool savedTiled: false                  // was in the tiling tree when fullscreen started
    readonly property bool activated: !!output && output.focusedWindow === win
    onActivatedChanged: { reconfigure(); if (!activated) termSettings.visible = false }
    property rect tileRect: Qt.rect(0, 0, 0, 0)
    function xdgStates(extra) {
        const s = []
        if (activated) s.push(XdgToplevel.ActivatedState)
        if (fullscreen) s.push(XdgToplevel.FullscreenState)
        else if (zoomed) s.push(XdgToplevel.MaximizedState)
        if (extra) for (const e of extra) s.push(e)
        return s
    }
    // the client's own limits (xdg set_min_size / set_max_size), in surface units
    function clampSize(w, h) {
        const mn = toplevel ? toplevel.minSize : Qt.size(0, 0), mx = toplevel ? toplevel.maxSize : Qt.size(0, 0)
        if (mn.width > 0) w = Math.max(w, mn.width)
        if (mn.height > 0) h = Math.max(h, mn.height)
        if (mx.width > 0) w = Math.min(w, mx.width)
        if (mx.height > 0) h = Math.min(h, mx.height)
        return Qt.size(Math.max(1, Math.round(w)), Math.max(1, Math.round(h)))
    }
    // size in surface units; fullscreen sizes are the output's and bypass the client's limits
    function configure(w, h, extra) {
        if (!toplevel) return
        const s = fullscreen ? Qt.size(Math.max(1, Math.round(w)), Math.max(1, Math.round(h))) : clampSize(w, h)
        toplevel.sendConfigure(s, xdgStates(extra))
    }
    // the current size again with the current states (focus, fullscreen or zoom changed)
    function reconfigure() {
        if (!toplevel) return
        if (fullscreen) applyFullscreen()
        else if (zoomed) applyZoom()
        else if (tiled && tileRect.width > 0) configure(tileRect.width / surfaceScale, (tileRect.height - titleHeight) / surfaceScale)
        else if (geo.width > 0) configure(geo.width, geo.height)
    }
    // Tiling assigns a rect: move the frame there and ask the client for the matching surface size.
    function setTileRect(r) {
        if (fullscreen) return
        zoomed = false
        tileRect = r; placed = true
        x = r.x; y = r.y
        configure(r.width / surfaceScale, (r.height - titleHeight) / surfaceScale)
    }
    function applyFullscreen() {
        if (!fullscreen || !parent) return
        x = 0; y = 0
        configure(parent.width / surfaceScale, parent.height / surfaceScale)
    }
    function setFullscreen(on) {
        if (on === fullscreen) return
        if (on) {
            savedTiled = tiled
            if (tiled && output) output.tilingOf(win).remove(win)
            else if (!zoomed) savedGeo = Qt.rect(x, y, geo.width, geo.height)
            fullscreen = true
            raise(); applyFullscreen()
        } else {
            fullscreen = false
            if (savedTiled && output && output.tilingEnabled && output.tileable(win) && output.tilingOf(win).add(win, null)) { raise(); return }
            if (zoomed) applyZoom()
            else if (savedGeo.width > 0) { x = savedGeo.x; y = savedGeo.y; configure(savedGeo.width, savedGeo.height) }
            else reconfigure()
            raise()
        }
    }
    function toggleFullscreen() { setFullscreen(!fullscreen) }
    function applyZoom() {
        if (!zoomed || !parent) return
        x = 20; y = 20
        configure((parent.width - 40) / surfaceScale, (parent.height - 40 - titleHeight) / surfaceScale)
    }
    // green button / title double-click / ⌘⌥F: maximize to the work area, floating; again restores
    function zoom() {
        if (fullscreen) return
        if (zoomed) { unzoom(); return }
        if (tiled && output) output.setFloating(win, true)
        savedGeo = Qt.rect(x, y, geo.width, geo.height)
        zoomed = true; raise(); applyZoom()
    }
    function unzoom() {
        if (!zoomed) return
        zoomed = false
        if (savedGeo.width > 0) { x = savedGeo.x; y = savedGeo.y; configure(savedGeo.width, savedGeo.height) }
        else reconfigure()
    }
    property int resizeEdges: 0          // non-zero while a ResizeHandle drags
    property real anchoredRight: 0
    property real anchoredBottom: 0

    // The client's window geometry (xdg_surface.set_window_geometry): GTK/Chromium surfaces carry
    // invisible shadow margins around the actual window, which must not show as padding in our frame.
    readonly property rect geo: (shellSurface && shellSurface.windowGeometry.width > 0 && shellSurface.windowGeometry.height > 0)
                                ? shellSurface.windowGeometry : Qt.rect(0, 0, surfaceItem.width, surfaceItem.height)
    width: geo.width * surfaceScale; height: geo.height * surfaceScale + titleHeight
    z: 0

    // Minimise/restore: a quick scale+fade instead of a genie. Other workspaces' windows are hidden.
    // helper surfaces stay rendered (frame callbacks keep flowing) but practically invisible: 1x1 at 1% opacity
    visible: opacity > 0
    opacity: helper ? 0.01 : ((minimized || !shownWorkspace) ? 0 : 1)
    scale: minimized ? 0.6 : 1
    transformOrigin: Item.Bottom
    Behavior on opacity { NumberAnimation { duration: 110 } }
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    property var quietItems: []           // popup items already set up by quietPopups
    function quietPopups(item) {
        for (const child of item.children) {
            if (child.focusOnClick === undefined || quietItems.indexOf(child) >= 0) continue
            child.focusOnClick = false
            quietItems.push(child)
            child.childrenChanged.connect(() => win.quietPopups(child))
            child.Component.onDestruction.connect(() => { const i = win.quietItems.indexOf(child); if (i >= 0) win.quietItems.splice(i, 1) })
            win.quietPopups(child)
        }
    }
    function raise() {
        let top = 0
        for (let i = 0; i < parent.children.length; ++i) top = Math.max(top, parent.children[i].z)
        z = top + 1
        if (mapped) surfaceItem.takeFocus()     // else: refocus() runs when the first buffer arrives
        if (output) output.focusedWindow = win
    }
    function minimize() {
        minimized = true
        if (output) { if (output.focusedWindow === win) output.focusedWindow = null; output.touch(); output.focusTopmost() }
    }
    function restore() {
        minimized = false
        if (output) output.touch()
        raise()
    }
    // First time we know our size: cascade within the layer and keep clear of its edges.
    function place() {
        if (placed || tiled || fullscreen || zoomed || width <= 0 || height <= titleHeight) return
        placed = true
        // Oversize first window (e.g. Chromium): ask the client for a size that fits the work area.
        if (width > parent.width - 40 || height > parent.height - 40)
            configure(Math.min(geo.width, (parent.width - 80) / surfaceScale), Math.min(geo.height, (parent.height - 80 - titleHeight) / surfaceScale))
        const step = 36
        let px = 60 + (cascadeIndex % 8) * step, py = 30 + (cascadeIndex % 8) * step
        px = Math.max(0, Math.min(px, parent.width - width))
        py = Math.max(0, Math.min(py, parent.height - height))
        x = px; y = py
    }
    onWidthChanged: { if (resizeEdges & Qt.LeftEdge) x = anchoredRight - width; else place() }
    onHeightChanged: { if (resizeEdges & Qt.TopEdge) y = anchoredBottom - height; else place() }
    onResizeEdgesChanged: { anchoredRight = x + width; anchoredBottom = y + height }

    // Shadow (self-decorated apps bring their own)
    Rectangle {
        visible: win.showTitle
        anchors.fill: frame; anchors.margins: -1; radius: win.radius + 1
        color: "transparent"; border.color: "#33000000"; border.width: 1
        Rectangle { anchors.fill: parent; anchors.margins: -6; radius: win.radius + 6; color: "#22000000"; z: -1 }
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        radius: win.showTitle ? win.radius : 0
        color: win.showTitle ? "#f2f2f4" : "transparent"
        clip: true

        // Title bar with traffic lights
        Rectangle {
            id: titleBar
            visible: win.showTitle
            width: parent.width; height: win.titleHeight
            color: win.output && win.output.focusedWindow === win ? "#e8e8ea" : "#f4f4f5"
            // Drag/raise/zoom area; declared first so the traffic lights below stack above it.
            MouseArea {
                anchors.fill: parent
                drag.target: win; drag.axis: Drag.XAndYAxis
                drag.minimumX: -win.width + 80; drag.maximumX: win.parent.width - 80
                drag.minimumY: 0; drag.maximumY: win.parent.height - win.titleHeight
                onPressed: win.raise()
                onPositionChanged: if (drag.active) { win.zoomed = false; if (win.tiled && win.output) win.output.setFloating(win, true) }
                onDoubleClicked: win.zoom()
            }
            Row {
                anchors.left: parent.left; anchors.leftMargin: Theme.px(12); anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.px(8)
                Rectangle { width: Theme.px(12); height: width; radius: width / 2; color: "#ff5f57"; border.color: "#e0443e"
                    MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: win.toplevel.sendClose() } }
                Rectangle { width: Theme.px(12); height: width; radius: width / 2; color: "#febc2e"; border.color: "#dea123"
                    MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: win.minimize() } }
                Rectangle { width: Theme.px(12); height: width; radius: width / 2; color: "#28c840"; border.color: "#1aab29"
                    MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: win.zoom() } }
            }
            Text {
                anchors.centerIn: parent
                text: win.title; color: "#3a3a3c"; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont; font.bold: true
                elide: Text.ElideRight; width: parent.width - 180; horizontalAlignment: Text.AlignHCenter
            }
            // terminal settings (text size, colours)
            Rectangle {
                id: termGear
                visible: win.isTerminal
                anchors.right: parent.right; anchors.rightMargin: Theme.px(14); anchors.verticalCenter: parent.verticalCenter
                width: Theme.px(24); height: width; radius: Theme.px(6)
                color: termSettings.visible ? "#d4d4d8" : gearMouse.containsMouse ? "#dedee2" : "transparent"
                Text { anchors.centerIn: parent; anchors.verticalCenterOffset: 1; text: "⚙"; color: "#4a4a4e"; font.pixelSize: Theme.fpx(15); font.family: Theme.uiFont }
                MouseArea { id: gearMouse; anchors.fill: parent; hoverEnabled: true
                    onClicked: { win.raise(); termSettings.visible = !termSettings.visible } }
            }
        }

        // The client's pixels
        ShellSurfaceItem {
            id: surfaceItem
            // shift so the window geometry's origin sits under the title bar; the margins are clipped by the frame
            x: -win.geo.x * win.surfaceScale
            y: win.titleHeight - win.geo.y * win.surfaceScale
            scale: win.surfaceScale; transformOrigin: Item.TopLeft
            shellSurface: win.shellSurface
            moveItem: win
            autoCreatePopupItems: true
            // Popup items (menus, and submenus inside them) must not take keyboard focus on click: the toplevel
            // losing focus makes Firefox and GTK close the menu on the press, so the release never picks an item.
            onChildrenChanged: win.quietPopups(surfaceItem)
            onSurfaceDestroyed: { if (win.output) win.output.removeWindow(win); win.destroy() }
            // Passive grab: raise on click without stealing the press from the client.
            TapHandler { gesturePolicy: TapHandler.DragThreshold; onPressedChanged: if (pressed) { termSettings.visible = false; win.raise() } }
        }

    }

    // ---- terminal settings popover ----
    // Text size: the window zooms right away through foot's own keys (Ctrl+plus/minus, 0.5 pt a step) and the size is
    // saved for new terminals. Colours: foot keeps the theme palette and a high-contrast one; SIGUSR1/SIGUSR2 switch a
    // running terminal, and the choice is saved for new ones.
    // Control+key to this terminal (Launcher.sendControlKey picks "+" or "=", whichever the layout has unshifted)
    function terminalKeys(keys, times) {
        const seat = output && output.compositor ? output.compositor.defaultSeat : null
        if (!seat) return
        surfaceItem.takeFocus()
        Launcher.sendControlKey(seat, keys, times)
    }
    function terminalZoom(step) {
        const pt = Math.max(6, Math.min(40, Theme.terminalFontPt + step))
        if (pt === Theme.terminalFontPt) return
        terminalKeys(step > 0 ? [Qt.Key_Plus, Qt.Key_Equal] : [Qt.Key_Minus], Math.max(1, Math.round(Theme.scale * 2)))   // 1 pt × scale
        Theme.setTerminalFontPt(pt)
    }
    function terminalContrast(on) {
        Theme.setTerminalContrast(on)
        const client = shellSurface && shellSurface.surface ? shellSurface.surface.client : null
        if (client) Launcher.setTerminalPalette(client.processId, on)
    }
    Rectangle {
        id: termSettings
        visible: false
        z: 250
        anchors.right: parent.right; anchors.rightMargin: Theme.px(8)
        y: win.titleHeight + Theme.px(4)
        width: Theme.px(268); height: termCol.implicitHeight + Theme.px(24)
        radius: Theme.px(10); color: "#f7f7f9"; border.color: "#c9c9ce"
        Rectangle { anchors.fill: parent; anchors.margins: -Theme.px(5); z: -1; radius: parent.radius + Theme.px(5); color: "#26000000" }
        MouseArea { anchors.fill: parent }          // keep clicks off the terminal underneath
        component PopButton: Rectangle {
            property string label; property bool selected: false; signal clicked()
            height: Theme.px(28); radius: Theme.px(6)
            color: selected ? "#2f6fea" : pm.pressed ? "#d0d0d6" : pm.containsMouse ? "#e3e3e8" : "#ececf0"
            border.color: selected ? "#2f6fea" : "#d2d2d8"
            Text { anchors.centerIn: parent; text: parent.label; color: parent.selected ? "white" : "#1c1c1e"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont }
            MouseArea { id: pm; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked() }
        }
        Column {
            id: termCol
            x: Theme.px(12); y: Theme.px(12); width: parent.width - Theme.px(24); spacing: Theme.px(10)
            Text { text: "TEXT SIZE"; color: "#6b6b72"; font.pixelSize: Theme.fpx(10); font.bold: true; font.family: Theme.uiFont }
            Row { spacing: Theme.px(6)
                PopButton { width: Theme.px(40); label: "A−"; onClicked: win.terminalZoom(-1) }
                Text { width: Theme.px(64); height: Theme.px(28); verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
                       text: Theme.terminalFontPt + " pt"; color: "#1c1c1e"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont }
                PopButton { width: Theme.px(40); label: "A+"; onClicked: win.terminalZoom(1) }
                PopButton { width: Theme.px(64); label: "Reset"; onClicked: { win.terminalKeys([Qt.Key_0], 1); Theme.setTerminalFontPt(11) } }
            }
            Text { text: "COLORS"; color: "#6b6b72"; font.pixelSize: Theme.fpx(10); font.bold: true; font.family: Theme.uiFont }
            Row { spacing: Theme.px(6)
                PopButton { width: (termCol.width - Theme.px(6)) / 2; label: "Theme"; selected: !Theme.terminalContrast; onClicked: win.terminalContrast(false) }
                PopButton { width: (termCol.width - Theme.px(6)) / 2; label: "High contrast"; selected: Theme.terminalContrast; onClicked: win.terminalContrast(true) }
            }
            Text { width: termCol.width; wrapMode: Text.WordWrap; color: "#6b6b72"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont
                   text: "Changes this window now and every new terminal." }
        }
    }

    // Omarchy-style ⌘ + left drag moves the window (floating it), ⌘ + right drag resizes it.
    MouseArea {
        id: superDrag
        anchors.fill: parent; z: 200
        enabled: (KeyGrab.modifiers & Qt.MetaModifier) !== 0
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property point last; property real sw; property real sh
        onPressed: (m) => {
            win.raise()
            if (win.fullscreen) return
            win.zoomed = false
            if (m.button === Qt.LeftButton && win.tiled && win.output) win.output.setFloating(win, true)
            last = mapToItem(null, m.x, m.y); sw = win.geo.width; sh = win.geo.height
        }
        onPositionChanged: (m) => {
            if (win.fullscreen) return
            const p = mapToItem(null, m.x, m.y)
            if (pressedButtons & Qt.LeftButton) { win.x += p.x - last.x; win.y += p.y - last.y; last = p }
            else if (pressedButtons & Qt.RightButton)
                win.configure(Math.max(240, sw + (p.x - last.x) / win.surfaceScale), Math.max(120, sh + (p.y - last.y) / win.surfaceScale), [XdgToplevel.ResizingState])
        }
        onReleased: (m) => { if (m.button === Qt.RightButton && !win.fullscreen) win.configure(win.geo.width, win.geo.height) }
    }

    // Resize handles on every edge and corner. The client picks the final size (xdg configure);
    // for left/top edges we keep the opposite edge fixed while the surface resizes.
    component ResizeHandle: MouseArea {
        property int edges          // Qt.LeftEdge | Qt.RightEdge | Qt.TopEdge | Qt.BottomEdge
        property real startW; property real startH; property point startPos
        property real fixedRight; property real fixedBottom
        enabled: !win.fullscreen
        hoverEnabled: true

        cursorShape: (edges === (Qt.LeftEdge | Qt.TopEdge) || edges === (Qt.RightEdge | Qt.BottomEdge)) ? Qt.SizeFDiagCursor
                   : (edges === (Qt.RightEdge | Qt.TopEdge) || edges === (Qt.LeftEdge | Qt.BottomEdge)) ? Qt.SizeBDiagCursor
                   : (edges & (Qt.LeftEdge | Qt.RightEdge)) ? Qt.SizeHorCursor : Qt.SizeVerCursor
        onPressed: (mouse) => {
            win.raise()
            win.zoomed = false
            startW = win.geo.width; startH = win.geo.height
            startPos = mapToItem(null, mouse.x, mouse.y)
            fixedRight = win.x + win.width; fixedBottom = win.y + win.height
            win.resizeEdges = edges
        }
        onPositionChanged: (mouse) => {
            if (!pressed) return
            const p = mapToItem(null, mouse.x, mouse.y)
            let dw = p.x - startPos.x, dh = p.y - startPos.y
            if (edges & Qt.LeftEdge) dw = -dw
            if (edges & Qt.TopEdge) dh = -dh
            if (!(edges & (Qt.LeftEdge | Qt.RightEdge))) dw = 0
            if (!(edges & (Qt.TopEdge | Qt.BottomEdge))) dh = 0
            win.configure(Math.max(240, startW + dw / win.surfaceScale), Math.max(120, startH + dh / win.surfaceScale), [XdgToplevel.ResizingState])
        }
        onReleased: {
            win.resizeEdges = 0
            win.configure(win.geo.width, win.geo.height)
        }

    }
    // grab zones: `outer` px outside the frame + `inner` px inside it; corners are `corner` square
    readonly property int outer: 12
    readonly property int inner: 4
    readonly property int corner: 22
    ResizeHandle { edges: Qt.LeftEdge;   x: -outer; y: corner; width: outer + inner; height: parent.height - 2 * corner }
    ResizeHandle { edges: Qt.RightEdge;  x: parent.width - inner; y: corner; width: outer + inner; height: parent.height - 2 * corner }
    ResizeHandle { edges: Qt.TopEdge;    x: corner; y: -outer; width: parent.width - 2 * corner; height: outer + inner }
    ResizeHandle { edges: Qt.BottomEdge; x: corner; y: parent.height - inner; width: parent.width - 2 * corner; height: outer + inner }
    // top corners: small, so they never cover the traffic lights (12 px in) or the terminal's settings button
    ResizeHandle { edges: Qt.LeftEdge | Qt.TopEdge;      x: -outer; y: -outer; width: outer + inner + 4; height: outer + inner + 4 }
    ResizeHandle { edges: Qt.RightEdge | Qt.TopEdge;     x: parent.width - inner - 4; y: -outer; width: outer + inner + 4; height: outer + inner + 4 }
    ResizeHandle { edges: Qt.LeftEdge | Qt.BottomEdge;   x: -outer; y: parent.height - corner; width: corner + outer; height: corner + outer }
    ResizeHandle { edges: Qt.RightEdge | Qt.BottomEdge;  x: parent.width - corner; y: parent.height - corner; width: corner + outer; height: corner + outer }
}
