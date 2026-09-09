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
    readonly property bool showTitle: Theme.titleBars === "always" || (Theme.titleBars === "auto" && !selfDecorated)
    readonly property int titleHeight: showTitle ? Theme.px(34) : 0
    onTitleHeightChanged: if (tiled && output && output.tiling) output.tiling.relayout()   // re-send the tile size
    readonly property int radius: Theme.px(12)
    // fractional UI scale is applied to the client surface as an item scale; integer scale is HiDPI in the client
    readonly property real surfaceScale: Theme.scale / Theme.outputScale
    property bool minimized: false
    property int workspace: 1
    // (not "onWorkspace": names starting with "on" + a capital read as signal handlers in QML)
    readonly property bool shownWorkspace: !output || output.workspace === workspace
    property bool placed: false
    property bool tiled: false
    property bool fullscreen: false
    property rect tileRect: Qt.rect(0, 0, 0, 0)
    // Tiling assigns a rect: move the frame there and ask the client for the matching surface size.
    function setTileRect(r) {
        tileRect = r; placed = true
        x = r.x; y = r.y
        toplevel.sendConfigure(Qt.size(Math.max(100, r.width / surfaceScale), Math.max(60, (r.height - titleHeight) / surfaceScale)), [XdgToplevel.ActivatedState])
    }
    function toggleFullscreen() {
        fullscreen = !fullscreen
        if (fullscreen) { raise(); toplevel.sendConfigure(Qt.size(parent.width / surfaceScale, (parent.height - titleHeight) / surfaceScale), [XdgToplevel.ActivatedState]); x = 0; y = 0 }
        else if (tiled && output) output.tiling.relayout()
        else zoom()
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
    visible: opacity > 0
    opacity: (minimized || !shownWorkspace) ? 0 : 1
    scale: minimized ? 0.6 : 1
    transformOrigin: Item.Bottom
    Behavior on opacity { NumberAnimation { duration: 110 } }
    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    function raise() {
        let top = 0
        for (let i = 0; i < parent.children.length; ++i) top = Math.max(top, parent.children[i].z)
        z = top + 1
        surfaceItem.takeFocus()
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
    function zoom() {
        raise()
        toplevel.sendConfigure(Qt.size((parent.width - 40) / surfaceScale, (parent.height - 40 - titleHeight) / surfaceScale), [XdgToplevel.ActivatedState])
        x = 20; y = 20
    }
    // First time we know our size: cascade within the layer and keep clear of its edges.
    function place() {
        if (placed || tiled || width <= 0 || height <= titleHeight) return
        placed = true
        // Oversize first window (e.g. Chromium): ask the client for a size that fits the work area.
        if (width > parent.width - 40 || height > parent.height - 40)
            toplevel.sendConfigure(Qt.size(Math.min(geo.width, (parent.width - 80) / surfaceScale),
                                           Math.min(geo.height, (parent.height - 80 - titleHeight) / surfaceScale)),
                                   [XdgToplevel.ActivatedState])
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
                onPositionChanged: if (drag.active && win.tiled && win.output) win.output.setFloating(win, true)
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
            onSurfaceDestroyed: { if (win.output) win.output.removeWindow(win); win.destroy() }
            // Passive grab: raise on click without stealing the press from the client.
            TapHandler { gesturePolicy: TapHandler.DragThreshold; onPressedChanged: if (pressed) win.raise() }
        }

    }

    // Resize handles on every edge and corner. The client picks the final size (xdg configure);
    // for left/top edges we keep the opposite edge fixed while the surface resizes.
    component ResizeHandle: MouseArea {
        property int edges          // Qt.LeftEdge | Qt.RightEdge | Qt.TopEdge | Qt.BottomEdge
        property real startW; property real startH; property point startPos
        property real fixedRight; property real fixedBottom
        hoverEnabled: true
        cursorShape: (edges === (Qt.LeftEdge | Qt.TopEdge) || edges === (Qt.RightEdge | Qt.BottomEdge)) ? Qt.SizeFDiagCursor
                   : (edges === (Qt.RightEdge | Qt.TopEdge) || edges === (Qt.LeftEdge | Qt.BottomEdge)) ? Qt.SizeBDiagCursor
                   : (edges & (Qt.LeftEdge | Qt.RightEdge)) ? Qt.SizeHorCursor : Qt.SizeVerCursor
        onPressed: (mouse) => {
            win.raise()
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
            const s = Qt.size(Math.max(240, startW + dw / win.surfaceScale), Math.max(120, startH + dh / win.surfaceScale))
            win.toplevel.sendConfigure(s, [XdgToplevel.ResizingState, XdgToplevel.ActivatedState])
        }
        onReleased: {
            win.resizeEdges = 0
            win.toplevel.sendConfigure(Qt.size(win.geo.width, win.geo.height), [XdgToplevel.ActivatedState])
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
    ResizeHandle { edges: Qt.LeftEdge | Qt.TopEdge;      x: -outer; y: -outer; width: corner + outer; height: corner + outer }
    ResizeHandle { edges: Qt.RightEdge | Qt.TopEdge;     x: parent.width - corner; y: -outer; width: corner + outer; height: corner + outer }
    ResizeHandle { edges: Qt.LeftEdge | Qt.BottomEdge;   x: -outer; y: parent.height - corner; width: corner + outer; height: corner + outer }
    ResizeHandle { edges: Qt.RightEdge | Qt.BottomEdge;  x: parent.width - corner; y: parent.height - corner; width: corner + outer; height: corner + outer }
}
