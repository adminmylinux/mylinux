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
    function workspaceOccupied(n) { return windows.some(w => w.workspace === n) }
    function switchWorkspace(n) {
        if (n < 1 || n > workspaces || n === workspace) return
        workspace = n
        focusedWindow = null
        windowsRevision++
        if (tiling) tiling.relayout()
        focusTopmost()
    }
    function moveToWorkspace(w, n) {
        if (!w || n < 1 || n > workspaces || w.workspace === n) return
        if (w.tiled) tilingOf(w).remove(w)
        w.workspace = n
        if (tilingEnabled && !w.minimized) tilings[n - 1].add(w, null)
        windowsRevision++
        switchWorkspace(n)
        w.raise()
    }
    function moveFocusedToWorkspace(n) { if (focusedWindow) moveToWorkspace(focusedWindow, n) }
    // Bring a window forward wherever it is (menu bar window list, dock).
    function activateWindow(w) {
        if (!w) return
        if (w.workspace !== workspace) switchWorkspace(w.workspace)
        if (w.minimized) w.restore(); else w.raise()
    }

    function addWindow(toplevel, xdgSurface) {
        const w = windowComponent.createObject(windowLayer, {
            toplevel: toplevel, shellSurface: xdgSurface, output: root, cascadeIndex: cascade++, workspace: workspace
        })
        windows.push(w); windowsRevision++
        if (tilingEnabled) tiling.add(w, focusedWindow)
        w.raise()
    }
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
        { group: "Apps", keys: [["⌘ Enter", "Terminal"], ["⌘ ⇧ Enter", "Browser (Firefox)"], ["⌘ T / ⌘ N", "New terminal"], ["⌘ Space", "Launcher"], ["⌘ ⌥ Space", "Menu"], ["⌘ K", "This list"]] },
        { group: "Windows", keys: [["⌘ W", "Close window"], ["⌘ Q", "Quit app"], ["⌘ M", "Minimise"], ["⌘ F", "Fullscreen"], ["⌘ V", "Float / tile window"], ["⌘ Tab", "Cycle windows"], ["⌘ ⇧ T", "Tiling on/off"]] },
        { group: "Tiling", keys: [["⌘ ← → ↑ ↓", "Focus window in direction"], ["⌘ ⇧ ← → ↑ ↓", "Swap with neighbour"], ["⌘ ⌃ ← → ↑ ↓", "Resize split"]] },
        { group: "Workspaces", keys: [["⌘ 1 … ⌘ 9", "Switch workspace"], ["⌘ ⇧ 1 … 9", "Move window to workspace (and follow)"], ["Menu bar numbers", "Occupied workspaces; click to switch"]] },
        { group: "Look", keys: [["⌘ ⌃ ⇧ Space", "Theme picker"], ["⌘ ⌃ Space", "Next background"], ["Menu bar icons", "Agents · Keyboard layout · Display"]] }
    ]
    function touch() { windowsRevision++ }

    function appIdOf(w) { return w.toplevel ? (w.toplevel.appId || "") : "" }
    function appNameFor(w) {
        if (!w) return "mylinux"
        const id = appIdOf(w)
        for (const a of dock.apps) if (a.appId === id) return a.name
        if (id === "myapp") return "Clock"
        return id || w.title || "mylinux"
    }
    function windowsFor(appId) { return windows.filter(w => appIdOf(w) === appId) }
    function visibleWindows() { return windows.filter(w => !w.minimized && w.workspace === workspace) }
    function currentWindows() { return windows.filter(w => w.workspace === workspace) }
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

    // ---- shortcuts (Cmd = Meta/Super; libinput maps it, the old evdev keymap could not) -------
    Shortcut { sequences: ["Meta+W"]; context: Qt.ApplicationShortcut; onActivated: root.closeFocused() }
    Shortcut { sequences: ["Meta+Q"]; context: Qt.ApplicationShortcut; onActivated: root.quitFocusedApp() }
    Shortcut { sequences: ["Meta+M"]; context: Qt.ApplicationShortcut; onActivated: root.minimizeFocused() }
    Shortcut { sequences: ["Meta+T", "Meta+N"]; context: Qt.ApplicationShortcut; onActivated: Launcher.launch("/usr/bin/foot") }
    Shortcut { sequences: ["Meta+Tab", "Meta+`"]; context: Qt.ApplicationShortcut; onActivated: root.cycleWindows() }
    Shortcut { sequences: ["Meta+Return", "Meta+Enter"]; context: Qt.ApplicationShortcut; onActivated: Launcher.launch("/usr/bin/foot") }
    Shortcut { sequences: ["Meta+Shift+Return", "Meta+Shift+Enter"]; context: Qt.ApplicationShortcut; onActivated: Launcher.launch("/usr/bin/firefox") }
    Shortcut { sequences: ["Meta+K"]; context: Qt.ApplicationShortcut; onActivated: keyHelp.visible = !keyHelp.visible }
    Shortcut { sequences: ["Meta+F"]; context: Qt.ApplicationShortcut; onActivated: if (root.focusedWindow) root.focusedWindow.toggleFullscreen() }
    Shortcut { sequences: ["Meta+V"]; context: Qt.ApplicationShortcut; onActivated: if (root.focusedWindow) root.setFloating(root.focusedWindow, root.focusedWindow.tiled) }
    Shortcut { sequences: ["Meta+Shift+T"]; context: Qt.ApplicationShortcut; onActivated: root.toggleTiling() }
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
    Shortcut { sequences: ["Meta+Space", "Alt+Space"]; context: Qt.ApplicationShortcut; onActivated: spotlight.open ? spotlight.hide() : spotlight.show("search") }
    Shortcut { sequences: ["Meta+Alt+Space", "Ctrl+Alt+Space"]; context: Qt.ApplicationShortcut; onActivated: spotlight.open ? spotlight.hide() : spotlight.show("menu") }
    Shortcut { sequences: ["Meta+Ctrl+Shift+Space"]; context: Qt.ApplicationShortcut; onActivated: spotlight.open ? spotlight.hide() : spotlight.show("theme") }
    Shortcut { sequences: ["Meta+Ctrl+Space"]; context: Qt.ApplicationShortcut; onActivated: Theme.nextBackground() }
    // Workspaces: ⌘1..9 switch, ⌘⇧1..9 move the focused window there and follow it. Shift turns the digit
    // keys into layout-dependent symbols, so KeyGrab (C++) matches them by physical key code.
    Connections { target: KeyGrab; function onDigit(n, shift) { if (shift) root.moveFocusedToWorkspace(n); else root.switchWorkspace(n) } }

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
            anchors.bottomMargin: dock.height + dock.anchors.bottomMargin + 6
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
