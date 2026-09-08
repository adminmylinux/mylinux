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

    property Tiling tiling: Tiling { area: windowLayer; enabled: String(Settings.value("wm/tiling", "true")) === "true" }
    function addWindow(toplevel, xdgSurface) {
        const w = windowComponent.createObject(windowLayer, {
            toplevel: toplevel, shellSurface: xdgSurface, output: root, cascadeIndex: cascade++
        })
        windows.push(w); windowsRevision++
        if (tiling.enabled) tiling.add(w, focusedWindow)
        w.raise()
    }
    function removeWindow(w) {
        const i = windows.indexOf(w)
        if (i >= 0) windows.splice(i, 1)
        if (w.tiled) tiling.remove(w)
        if (focusedWindow === w) focusedWindow = null
        windowsRevision++
        focusTopmost()
    }
    function setFloating(w, floating) {
        if (floating && w.tiled) { tiling.remove(w); w.raise() }
        else if (!floating && !w.tiled) tiling.add(w, focusedWindow)
    }
    function toggleTiling() {
        tiling.enabled = !tiling.enabled; Settings.set("wm/tiling", tiling.enabled ? "true" : "false")
        if (tiling.enabled) { for (const w of windows) if (!w.tiled && !w.minimized) tiling.add(w, null) }
        else { for (const w of windows.slice()) if (w.tiled) tiling.remove(w) }
    }
    function focusDir(dir) { if (!focusedWindow) { focusTopmost(); return } const n = tiling.neighbour(focusedWindow, dir); if (n) n.raise() }
    function swapDir(dir) { if (focusedWindow) tiling.swap(focusedWindow, dir) }
    function resizeDir(dir) { if (focusedWindow) tiling.resize(focusedWindow, dir) }
    // Single source of truth for the key help (⌘ = the Super/Option key)
    readonly property var keybindings: [
        { group: "Apps", keys: [["⌘ Enter", "Terminal"], ["⌘ ⇧ Enter", "Browser (Firefox)"], ["⌘ T / ⌘ N", "New terminal"], ["⌘ Space", "Launcher"], ["⌘ ⌥ Space", "Menu"], ["⌘ K", "This list"]] },
        { group: "Windows", keys: [["⌘ W", "Close window"], ["⌘ Q", "Quit app"], ["⌘ M", "Minimise"], ["⌘ F", "Fullscreen"], ["⌘ V", "Float / tile window"], ["⌘ Tab", "Cycle windows"], ["⌘ ⇧ T", "Tiling on/off"]] },
        { group: "Tiling", keys: [["⌘ ← → ↑ ↓", "Focus window in direction"], ["⌘ ⇧ ← → ↑ ↓", "Swap with neighbour"], ["⌘ ⌃ ← → ↑ ↓", "Resize split"]] },
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
    function visibleWindows() { return windows.filter(w => !w.minimized) }
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
    // Dock icon click: restore minimised windows, else raise, else launch.
    function activateApp(appId, exec) {
        const mine = windowsFor(appId)
        if (mine.length === 0) { Launcher.launch(exec); return }
        const minimized = mine.filter(w => w.minimized)
        if (minimized.length > 0) { for (const w of minimized) w.restore(); return }
        const t = topmost(mine); if (t) t.raise()
    }
    // Cmd-Tab: cycle through all windows (restoring minimised ones), lowest first.
    function cycleWindows() {
        if (windows.length === 0) return
        let lowest = null
        for (const w of windows) if (!lowest || w.z < lowest.z) lowest = w
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
            onWidthChanged: root.tiling.relayout()
            onHeightChanged: root.tiling.relayout()
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
