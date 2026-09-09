import QtQuick
import QtWayland.Compositor
import MyShell

Window {
    id: root
    property var compositor
    visible: true
    color: "#0b0f14"
    title: "mylinux shell"

    // ---- window bookkeeping -------------------------------------------------------------
    // All MacWindow items, in creation order. windowsRevision bumps whenever the set or a
    // window's minimised state changes, so bindings that call the helpers below refresh.
    property var windows: []
    property int windowsRevision: 0
    property Item focusedWindow: null
    property int cascade: 0

    // ---- workspaces (Omarchy-style): ⌘1..⌘9 switch, ⌘⇧1..9 move the focused window and follow ----
    // Every window carries a workspace number; only the current workspace's windows are shown.
    // Each workspace has its own dwindle tiling tree.
    readonly property int workspaces: 9
    property int workspace: 1
    property bool tilingEnabled: String(Settings.value("wm/tiling", "true")) === "true"
    property var tilings: []
    property Tiling tiling: tilings.length ? tilings[workspace - 1] : null
    Component { id: tilingComponent; Tiling { area: windowLayer } }
    Component.onCompleted: { const t = []; for (let i = 0; i < workspaces; ++i) t.push(tilingComponent.createObject(root)); tilings = t }
    function tilingOf(w) { return tilings[(w.workspace || 1) - 1] }
    function workspaceOccupied(n) { return windows.some(w => !w.helper && w.workspace === n) }
    function switchWorkspace(n) {
        if (n < 1 || n > workspaces || n === workspace) return
        workspace = n
        focusedWindow = null
        windowsRevision++
        if (tiling) tiling.relayout()
        focusTopmost()
    }
    function moveToWorkspace(w, n, follow) {
        if (!w || n < 1 || n > workspaces || (w.workspace === n && !w.scratch)) return
        if (w.tiled) tilingOf(w).remove(w)
        w.scratch = false
        w.workspace = n
        if (tilingEnabled && !w.minimized) tilings[n - 1].add(w, null)
        windowsRevision++
        if (follow === false) { if (focusedWindow === w) focusedWindow = null; focusTopmost(); return }
        switchWorkspaceTracked(n)
        w.raise()
    }
    function moveFocusedToWorkspace(n, follow) { if (focusedWindow) moveToWorkspace(focusedWindow, n, follow !== false) }
    property int previousWorkspace: 1
    onWorkspaceChanged: {}
    function switchWorkspaceTracked(n) { if (n !== workspace) { previousWorkspace = workspace; switchWorkspace(n) } }
    function nextWorkspace() { switchWorkspaceTracked(workspace % workspaces + 1) }
    function prevWorkspace() { switchWorkspaceTracked((workspace + workspaces - 2) % workspaces + 1) }
    function formerWorkspace() { switchWorkspaceTracked(previousWorkspace) }
    // Scratchpad (Omarchy ⌘S): windows moved there float above whatever workspace is current, shown or hidden as a set.
    property bool scratchVisible: false
    function toggleScratch() {
        if (!windows.some(w => w.scratch && !w.helper)) return
        scratchVisible = !scratchVisible; windowsRevision++
        if (scratchVisible) { for (const w of windows) if (w.scratch) w.raise() } else { focusedWindow = null; focusTopmost() }
    }
    function moveFocusedToScratch() {
        const w = focusedWindow; if (!w || w.scratch) return
        if (w.tiled) tilingOf(w).remove(w)
        w.scratch = true; scratchVisible = false; focusedWindow = null; windowsRevision++; focusTopmost()
    }
    function toggleSplit() { if (focusedWindow && focusedWindow.tiled) tilingOf(focusedWindow).toggleSplit(focusedWindow) }
    function closeAll() { for (const w of realWindows()) w.toplevel.sendClose() }
    function screenshot() {
        const d = new Date(), pad = n => (n < 10 ? "0" : "") + n
        const f = "/root/screenshot-" + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + "-" + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds()) + ".png"
        backdrop.grabToImage(r => { r.saveToFile(f); console.log("screenshot saved:", f) })
    }
    function scaleStep(up) {
        const steps = [1, 1.25, 1.5, 2]
        let i = steps.findIndex(v => Math.abs(v - Theme.scale) < 0.01); if (i < 0) i = 0
        i = Math.max(0, Math.min(steps.length - 1, i + (up ? 1 : -1))); Theme.setScale(steps[i])
    }
    // Bring a window forward wherever it is (menu bar window list, dock).
    function activateWindow(w) {
        if (!w) return
        if (w.scratch) { scratchVisible = true; windowsRevision++ }
        else if (w.workspace !== workspace) switchWorkspaceTracked(w.workspace)
        if (w.minimized) w.restore(); else w.raise()
    }

    function addWindow(toplevel, xdgSurface) {
        const w = windowComponent.createObject(windowLayer, {
            toplevel: toplevel, shellSurface: xdgSurface, output: root, cascadeIndex: cascade++, workspace: workspace
        })
        windows.push(w); windowsRevision++
        // Tiling waits for the app id (set right after creation, before the first commit, so the tile size
        // still reaches the client before it draws). A surface that maps without one is a helper.
        if (toplevel.appId) finishAdd(w)
    }
    // Apps that open floating instead of tiled (TUI tools with a fixed useful size, like Omarchy's)
    readonly property var floatingApps: ["activity"]
    function finishAdd(w) {
        if (w.added) return
        w.added = true
        if (tilingEnabled && floatingApps.indexOf(appIdOf(w)) < 0) tiling.add(w, focusedWindow)
        w.raise()
    }
    // First buffer arrived. No app id and a 1x1 buffer or the title "wl-clipboard" = wl-clipboard's popup (it
    // only wants keyboard focus for a serial / the selection offer): keep it invisible, hand it focus briefly,
    // then give focus back.
    function windowMapped(w) {
        if (w.added) return
        const t = w.toplevel ? (w.toplevel.title || "") : ""
        if (appIdOf(w) === "" && (t === "" || t === "wl-clipboard" || (w.geo.width <= 2 && w.geo.height <= 2))) {
            w.helper = true; w.added = true; windowsRevision++
            w.x = 0; w.y = 0
            w.takeKeyboardFocus()
            if (compositor && compositor.defaultSeat && w.shellSurface) compositor.defaultSeat.keyboardFocus = w.shellSurface.surface
            helperFocusBack.restart()
        } else finishAdd(w)
    }
    Timer { id: helperFocusBack; interval: 400; onTriggered: root.focusTopmost() }
    function realWindows() { return windows.filter(w => !w.helper) }
    // Guest -> Mac clipboard on request (⌘⌃C, like Omarchy's Ctrl+Alt+C): clipboard-send writes it to the share
    function sendClipboardToMac() { Launcher.launch("/usr/bin/clipboard-send") }
    function removeWindow(w) {
        const i = windows.indexOf(w)
        if (i >= 0) windows.splice(i, 1)
        if (w.tiled) tilingOf(w).remove(w)
        if (focusedWindow === w) focusedWindow = null
        windowsRevision++
        focusTopmost()
    }
    function setFloating(w, floating) {
        if (floating && w.tiled) { tilingOf(w).remove(w); w.raise() }
        else if (!floating && !w.tiled) tilingOf(w).add(w, w.workspace === workspace ? focusedWindow : null)
    }
    function toggleTiling() {
        tilingEnabled = !tilingEnabled; Settings.set("wm/tiling", tilingEnabled ? "true" : "false")
        if (tilingEnabled) { for (const w of windows) if (!w.tiled && !w.minimized) tilingOf(w).add(w, null) }
        else { for (const w of windows.slice()) if (w.tiled) tilingOf(w).remove(w) }
    }
    function focusDir(dir) { if (!focusedWindow) { focusTopmost(); return } const n = tiling.neighbour(focusedWindow, dir); if (n) n.raise() }
    function swapDir(dir) { if (focusedWindow) tiling.swap(focusedWindow, dir) }
    function resizeDir(dir) { if (focusedWindow) tiling.resize(focusedWindow, dir) }
    // Single source of truth for the key help (⌘ = the Super/Option key)
    readonly property var keybindings: [
        { group: "Apps", keys: [["⌘ Enter", "Terminal"], ["⌘ ⇧ Enter", "Browser (Firefox)"], ["⌘ ⇧ F", "Files"], ["⌘ Space / ⌘ Esc", "Menu: type to find anything"], ["⌘ ⇧ Esc", "System menu"], ["⌘ K", "This list"]] },
        { group: "Windows", keys: [["⌘ W / ⌘ Q", "Close window"], ["⌘ M", "Minimise"], ["⌘ F / ⌘ ⌥ F", "Full screen / full width"], ["⌘ T", "Float / tile window"], ["⌘ J", "Toggle split direction"], ["⌘ ⇧ T", "Tiling on/off"], ["⌘ + drag", "Move window (⌘ + right drag: resize)"], ["⌥ Tab", "Cycle windows (GRAB=full)"], ["⌃ ⌥ ⌫", "Close all windows"]] },
        { group: "Tiling", keys: [["⌘ ← → ↑ ↓", "Focus window in direction"], ["⌘ ⇧ ← → ↑ ↓", "Swap with neighbour"], ["⌘ ⌃ ← → ↑ ↓", "Resize split"]] },
        { group: "Workspaces", keys: [["⌘ 1 … ⌘ 9", "Switch workspace"], ["⌘ ⇧ 1 … 9", "Move window there, follow it"], ["⌘ ⇧ ⌥ 1 … 9", "Move window there silently"], ["⌘ Tab / ⌘ ⇧ Tab", "Next / previous workspace"], ["⌘ ⌃ Tab", "Former workspace"], ["⌘ S", "Show / hide the scratchpad"], ["⌘ ⌥ S", "Move window to the scratchpad"], ["Menu bar numbers", "Occupied ones, click to switch"]] },
        { group: "Look", keys: [["⌘ ⌃ ⇧ Space", "Theme picker"], ["⌘ ⌃ Space", "Next background"], ["⌘ / and ⌘ ⌥ /", "Scale up / down"], ["Print", "Screenshot to your home"], ["⌘ ⌃ C", "Send clipboard to Mac"], ["Menu bar icons", "Activity · Tailscale · Agents · Keyboard · Display · Settings"]] }
    ]
    function touch() { windowsRevision++ }
    // Dock auto-hide: revealed while the pointer is at the bottom edge or over the dock, hidden shortly after it leaves
    property bool dockRevealed: false
    function dockLeave() { dockHideTimer.restart() }
    Timer { id: dockHideTimer; interval: 600; onTriggered: if (!dock.hovered && !dockEdge.containsMouse) root.dockRevealed = false }

    function appIdOf(w) { return w.toplevel ? (w.toplevel.appId || "") : "" }
    function appNameFor(w) {
        if (!w) return "mylinux"
        const id = appIdOf(w)
        for (const a of dock.apps) if (a.appId === id) return a.name
        if (id === "myapp") return "Clock"
        if (id === "activity") return "Activity"
        return id || w.title || "mylinux"
    }
    function windowsFor(appId) { return windows.filter(w => !w.helper && appIdOf(w) === appId) }
    function visibleWindows() { return windows.filter(w => !w.helper && !w.minimized && (w.scratch ? scratchVisible : w.workspace === workspace)) }
    function currentWindows() { return windows.filter(w => !w.helper && (w.scratch ? scratchVisible : w.workspace === workspace)) }
    function hasMinimized(appId) { return windowsFor(appId).some(w => w.minimized) }
    function isRunning(appId) { return windowsFor(appId).length > 0 }

    function topmost(list) {
        let best = null
        for (const w of list) if (!best || w.z > best.z) best = w
        return best
    }
    function focusTopmost() {
        const t = topmost(visibleWindows())
        if (t) t.raise()
    }
    // Dock icon click: windows on this workspace first (restore minimised, else raise); otherwise
    // switch to the workspace of the app's topmost window; otherwise launch.
    function activateApp(appId, exec) {
        const mine = windowsFor(appId)
        if (mine.length === 0) { Launcher.launch(exec); return }
        const here = mine.filter(w => w.workspace === workspace)
        if (here.length === 0) { activateWindow(topmost(mine)); return }
        const minimized = here.filter(w => w.minimized)
        if (minimized.length > 0) { for (const w of minimized) w.restore(); return }
        const t = topmost(here); if (t) t.raise()
    }
    // Cmd-Tab: cycle through this workspace's windows (restoring minimised ones), lowest first.
    function cycleWindows() {
        const list = currentWindows()
        if (list.length === 0) return
        let lowest = null
        for (const w of list) if (!lowest || w.z < lowest.z) lowest = w
        if (lowest.minimized) lowest.restore(); else lowest.raise()
    }
    function launch(exec) { Launcher.launch(exec) }
    function launchArgs(exec, args) { Launcher.launch(exec, args) }
    function dockApps() { return dock.apps }
    function openDisplayPanel() { menuBar.displayOpen = true }
    function openSpotlight(m) { spotlight.show(m) }
    function showKeys() { keyHelp.visible = true }
    function closeFocused() { if (focusedWindow) focusedWindow.toplevel.sendClose() }
    function showAbout() { about.visible = true }
    function systemRestart() { Launcher.launch("/sbin/reboot") }
    function systemShutdown() { Launcher.launch("/sbin/poweroff") }
    function quitFocusedApp() {
        if (!focusedWindow) return
        for (const w of windowsFor(appIdOf(focusedWindow))) w.toplevel.sendClose()
    }
    function minimizeFocused() { if (focusedWindow) focusedWindow.minimize() }

    // ---- shortcuts, Omarchy's set (⌘ = Meta/Super, the Option key; Alt = the Mac Cmd key, which macOS keeps
    // unless GRAB=full). Super+digit combinations come from KeyGrab (C++), the rest are QML shortcuts.
    Shortcut { sequences: ["Meta+W", "Meta+Q", "Ctrl+Alt+W"]; context: Qt.ApplicationShortcut; onActivated: root.closeFocused() }
    Shortcut { sequences: ["Ctrl+Alt+Del", "Ctrl+Alt+Delete"]; context: Qt.ApplicationShortcut; onActivated: root.closeAll() }
    Shortcut { sequences: ["Meta+M"]; context: Qt.ApplicationShortcut; onActivated: root.minimizeFocused() }
    Shortcut { sequences: ["Meta+Return", "Meta+Enter", "Meta+N"]; context: Qt.ApplicationShortcut; onActivated: Launcher.launch("/usr/bin/foot") }
    Shortcut { sequences: ["Meta+Shift+Return", "Meta+Shift+Enter", "Meta+Shift+B"]; context: Qt.ApplicationShortcut; onActivated: Launcher.launch("/usr/bin/firefox") }
    Shortcut { sequences: ["Meta+Shift+F"]; context: Qt.ApplicationShortcut; onActivated: Launcher.launch("/usr/bin/files") }
    Shortcut { sequences: ["Meta+K"]; context: Qt.ApplicationShortcut; onActivated: keyHelp.visible = !keyHelp.visible }
    Shortcut { sequences: ["Meta+F", "Meta+Alt+F", "Meta+Ctrl+F"]; context: Qt.ApplicationShortcut; onActivated: if (root.focusedWindow) root.focusedWindow.toggleFullscreen() }
    Shortcut { sequences: ["Meta+T"]; context: Qt.ApplicationShortcut; onActivated: if (root.focusedWindow) root.setFloating(root.focusedWindow, root.focusedWindow.tiled) }
    Shortcut { sequences: ["Meta+J"]; context: Qt.ApplicationShortcut; onActivated: root.toggleSplit() }
    Shortcut { sequences: ["Meta+Shift+T"]; context: Qt.ApplicationShortcut; onActivated: root.toggleTiling() }
    Shortcut { sequences: ["Alt+Tab"]; context: Qt.ApplicationShortcut; onActivated: root.cycleWindows() }
    Shortcut { sequences: ["Alt+Shift+Tab", "Alt+Shift+Backtab"]; context: Qt.ApplicationShortcut; onActivated: root.cycleWindows() }
    Shortcut { sequences: ["Meta+Left"]; context: Qt.ApplicationShortcut; onActivated: root.focusDir("left") }
    Shortcut { sequences: ["Meta+Right"]; context: Qt.ApplicationShortcut; onActivated: root.focusDir("right") }
    Shortcut { sequences: ["Meta+Up"]; context: Qt.ApplicationShortcut; onActivated: root.focusDir("up") }
    Shortcut { sequences: ["Meta+Down"]; context: Qt.ApplicationShortcut; onActivated: root.focusDir("down") }
    Shortcut { sequences: ["Meta+Shift+Left"]; context: Qt.ApplicationShortcut; onActivated: root.swapDir("left") }
    Shortcut { sequences: ["Meta+Shift+Right"]; context: Qt.ApplicationShortcut; onActivated: root.swapDir("right") }
    Shortcut { sequences: ["Meta+Shift+Up"]; context: Qt.ApplicationShortcut; onActivated: root.swapDir("up") }
    Shortcut { sequences: ["Meta+Shift+Down"]; context: Qt.ApplicationShortcut; onActivated: root.swapDir("down") }
    Shortcut { sequences: ["Meta+Ctrl+Left"]; context: Qt.ApplicationShortcut; onActivated: root.resizeDir("left") }
    Shortcut { sequences: ["Meta+Ctrl+Right"]; context: Qt.ApplicationShortcut; onActivated: root.resizeDir("right") }
    Shortcut { sequences: ["Meta+Ctrl+Up"]; context: Qt.ApplicationShortcut; onActivated: root.resizeDir("up") }
    Shortcut { sequences: ["Meta+Ctrl+Down"]; context: Qt.ApplicationShortcut; onActivated: root.resizeDir("down") }
    Shortcut { sequences: ["Meta+Tab"]; context: Qt.ApplicationShortcut; onActivated: root.nextWorkspace() }
    Shortcut { sequences: ["Meta+Shift+Tab", "Meta+Shift+Backtab"]; context: Qt.ApplicationShortcut; onActivated: root.prevWorkspace() }
    Shortcut { sequences: ["Meta+Ctrl+Tab"]; context: Qt.ApplicationShortcut; onActivated: root.formerWorkspace() }
    Shortcut { sequences: ["Meta+S", "Meta+`"]; context: Qt.ApplicationShortcut; onActivated: root.toggleScratch() }
    Shortcut { sequences: ["Meta+Alt+S", "Meta+Shift+`", "Meta+Shift+~"]; context: Qt.ApplicationShortcut; onActivated: root.moveFocusedToScratch() }
    Shortcut { sequences: ["Meta+Space", "Meta+Esc", "Meta+Escape", "Ctrl+Alt+Esc", "Ctrl+Alt+Escape", "Meta+Alt+Space", "Ctrl+Alt+Space"]; context: Qt.ApplicationShortcut; onActivated: spotlight.open ? spotlight.hide() : spotlight.show("menu") }
    Shortcut { sequences: ["Meta+Shift+Esc", "Meta+Shift+Escape"]; context: Qt.ApplicationShortcut; onActivated: spotlight.showCategory("system") }
    Shortcut { sequences: ["Meta+Ctrl+Shift+Space"]; context: Qt.ApplicationShortcut; onActivated: spotlight.open ? spotlight.hide() : spotlight.show("theme") }
    Shortcut { sequences: ["Meta+Ctrl+Space"]; context: Qt.ApplicationShortcut; onActivated: Theme.nextBackground() }
    Shortcut { sequences: ["Meta+/"]; context: Qt.ApplicationShortcut; onActivated: root.scaleStep(true) }
    Shortcut { sequences: ["Meta+Alt+/"]; context: Qt.ApplicationShortcut; onActivated: root.scaleStep(false) }
    Shortcut { sequences: ["Print", "SysReq"]; context: Qt.ApplicationShortcut; onActivated: root.screenshot() }
    Shortcut { sequences: ["Meta+Ctrl+C", "Ctrl+Alt+C"]; context: Qt.ApplicationShortcut; onActivated: root.sendClipboardToMac() }
    // Workspaces: ⌘1..9 switch, ⌘⇧1..9 move the focused window there and follow, ⌘⇧⌥1..9 move silently.
    // Shift turns the digit keys into layout-dependent symbols, so KeyGrab (C++) matches them by physical key code.
    Connections { target: KeyGrab; function onDigit(n, shift, alt) { if (shift) root.moveFocusedToWorkspace(n, !alt); else root.switchWorkspaceTracked(n) } }

    // ---- scene ----------------------------------------------------------------------------
    // Everything the glass panels blur: wallpaper + windows.
    Item {
        id: backdrop
        anchors.fill: parent
        // Wallpaper (shell/assets/wallpaper.png, generated by tools/gen-wallpaper.py), gradient fallback beneath.
        Rectangle { anchors.fill: parent; color: Theme.bg }
        Image {
            anchors.fill: parent
            source: Theme.background
            fillMode: Image.PreserveAspectCrop
            asynchronous: true; cache: false; smooth: true
        }
        Item {
            id: windowLayer
            anchors.fill: parent
            anchors.topMargin: menuBar.height
            anchors.bottomMargin: Theme.dockAutoHide ? Theme.px(6) : dock.height + Theme.px(10) + 6
            onWidthChanged: if (root.tiling) root.tiling.relayout()
            onHeightChanged: if (root.tiling) root.tiling.relayout()
        }
    }

    // Click-away layer: while a menu is open, any click outside it closes the menu.
    MouseArea {
        anchors.fill: parent
        z: 5
        visible: menuBar.openIndex >= 0
        onPressed: menuBar.openIndex = -1
    }

    Component { id: windowComponent; MacWindow {} }

    MouseArea { id: dockEdge; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right; height: Theme.px(16); z: 7   // reveal zone (hover only, clicks pass through)
               hoverEnabled: true; acceptedButtons: Qt.NoButton; onEntered: root.dockRevealed = true; onExited: dockHideTimer.restart() }
    Dock { id: dock; z: 8; desktop: root; backdrop: backdrop; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter }
    MenuBar { id: menuBar; z: 10; desktop: root; backdrop: backdrop; width: parent.width
              appName: root.appNameFor(root.focusedWindow) }

    // Display settings popover (opened from the menu bar icon)
    DisplayPanel {
        id: displayPanel
        z: 15
        visible: menuBar.displayOpen
        backdrop: backdrop
        anchors.top: menuBar.bottom; anchors.topMargin: Theme.px(6)
        anchors.right: parent.right; anchors.rightMargin: Theme.px(10)
    }
    MouseArea { anchors.fill: parent; z: 14; visible: menuBar.displayOpen; onPressed: menuBar.displayOpen = false }
    AgentPanel {
        id: agentPanel
        z: 15
        visible: menuBar.agentOpen
        backdrop: backdrop
        anchors.top: menuBar.bottom; anchors.topMargin: Theme.px(6)
        anchors.right: parent.right; anchors.rightMargin: Theme.px(10)
    }
    MouseArea { anchors.fill: parent; z: 14; visible: menuBar.agentOpen; onPressed: menuBar.agentOpen = false }
    TailscalePanel {
        z: 15
        visible: menuBar.tailscaleOpen
        backdrop: backdrop; desktop: root
        anchors.top: menuBar.bottom; anchors.topMargin: Theme.px(6)
        anchors.right: parent.right; anchors.rightMargin: Theme.px(10)
    }
    MouseArea { anchors.fill: parent; z: 14; visible: menuBar.tailscaleOpen; onPressed: menuBar.tailscaleOpen = false }
    SettingsPanel {
        z: 15
        visible: menuBar.settingsOpen
        backdrop: backdrop; desktop: root
        anchors.top: menuBar.bottom; anchors.topMargin: Theme.px(6)
        anchors.right: parent.right; anchors.rightMargin: Theme.px(10)
    }
    MouseArea { anchors.fill: parent; z: 14; visible: menuBar.settingsOpen; onPressed: menuBar.settingsOpen = false }
    MouseArea { anchors.fill: parent; z: 5; visible: menuBar.kbdOpen; onPressed: menuBar.closeKbd() }

    // Software brightness: dim everything (the hardware cursor stays bright, fine)
    Rectangle { anchors.fill: parent; z: 50; color: "black"; opacity: 1 - Theme.brightness; visible: opacity > 0.005 }

    Spotlight { id: spotlight; desktop: root; backdrop: backdrop }
    KeyHelp { id: keyHelp; backdrop: backdrop; desktop: root; bindings: root.keybindings; visible: false }
    FirstRun { backdrop: backdrop; desktop: root }

    // About panel
    Item {
        id: about
        z: 20
        visible: false
        anchors.centerIn: parent; width: 360; height: 220
        GlassPanel { anchors.fill: parent; backdrop: backdrop; radius: 16; tint: "#b8f6f6f8"; borderColor: "#66ffffff"; saturation: 0.1 }
        Column {
            anchors.centerIn: parent; spacing: 8
            AppIcon { kind: "clock"; size: 64; anchors.horizontalCenter: parent.horizontalCenter }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "mylinux"; font.pixelSize: 20; font.bold: true; font.family: Theme.uiFont; color: "#1c1c1e" }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Buildroot 2026.08 · Linux 6.18 · Qt 6.11"; font.pixelSize: 12; font.family: Theme.uiFont; color: "#3a3a3c" }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Wayland compositor shell, running from RAM"; font.pixelSize: 12; font.family: Theme.uiFont; color: "#3a3a3c" }
        }
        MouseArea { anchors.fill: parent; onClicked: about.visible = false }
    }
}
