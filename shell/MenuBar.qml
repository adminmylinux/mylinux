import QtQuick

// Menu bar with drop-down menus. `desktop` provides window state and actions.
Item {
    id: bar
    property var desktop
    property Item backdrop
    property string appName: "mylinux"
    height: Theme.px(20)      // slimmer than the 24 pt macOS bar, per user preference
    property bool displayOpen: false
    property bool agentOpen: false
    function closeKbd() { kbdIcon.open = false }
    readonly property bool kbdOpen: kbdIcon.open
    // 0 = none; menus open on click, and switch on hover while one is open (macOS behaviour)
    property int openIndex: -1
    readonly property string mod: "⌘"

    function windowItems() {
        if (!desktop) return []
        return desktop.realWindows().map(w => ({ label: (w.workspace !== desktop.workspace ? "[" + w.workspace + "] " : "") + (w.minimized ? "◇ " : "") + w.title, action: "window", win: w }))
    }
    property var menus: [
        { title: "⌘", logo: true, items: [
            { label: "About mylinux", action: "about" }, { sep: true },
            { label: "Menu / Search", action: "menu", shortcut: mod + "Space" },
            { label: "Theme…", action: "theme", shortcut: mod + "⌃⇧Space" },
            { label: "Next Background", action: "background", shortcut: mod + "⌃Space" }, { sep: true },
            { label: "Restart…", action: "restart" }, { label: "Shut Down…", action: "shutdown" } ] },
        { title: bar.appName, bold: true, items: [
            { label: "About " + bar.appName, action: "about" }, { sep: true },
            { label: "Hide " + bar.appName, action: "minimize", shortcut: mod + "M" },
            { label: "Quit " + bar.appName, action: "quit", shortcut: mod + "Q" } ] },
        { title: "File", items: [
            { label: "New Terminal", action: "terminal", shortcut: mod + "Enter" },
            { label: "New Clock", action: "clock" },
            { label: "New Firefox Window", action: "firefox" },
            { label: "New Chromium Window", action: "browser" },
            { label: "Remote Desktop (Remmina)", action: "remote" },
            { label: "ChatGPT", action: "chatgpt" }, { label: "Claude", action: "claude" }, { label: "Claude Code", action: "claudecode" }, { label: "Codex", action: "codex" }, { sep: true },
            { label: "Close Window", action: "close", shortcut: mod + "W" } ] },
        { title: "Edit", items: [
            { label: "Undo", disabled: true }, { label: "Redo", disabled: true }, { sep: true },
            { label: "Cut", disabled: true }, { label: "Copy", disabled: true }, { label: "Paste", disabled: true } ] },
        { title: "View", items: [
            { label: "Zoom", action: "zoom" }, { label: "Cycle Windows", action: "cycle", shortcut: "⌥Tab" }, { label: "Screenshot", action: "screenshot", shortcut: "Print" } ] },
        { title: "Window", dynamic: true, items: [
            { label: "Minimize", action: "minimize", shortcut: mod + "M" }, { label: "Zoom", action: "zoom" },
            { label: "Fullscreen", action: "fullscreen", shortcut: mod + "F" }, { label: "Float / Tile", action: "float", shortcut: mod + "T" },
            { label: "Tiling on/off", action: "tiling", shortcut: mod + "⇧T" },
            { label: "Title bars: " + Theme.titleBars + " (click to change)", action: "titlebars" }, { label: "Keybindings", action: "keys", shortcut: mod + "K" }, { sep: true } ] },
        { title: "Help", items: [ { label: "mylinux Help", disabled: true } ] }
    ]
    function itemsFor(i) {
        const m = menus[i]
        return m.dynamic ? m.items.concat(windowItems()) : m.items
    }
    function activate(item) {
        openIndex = -1
        if (!desktop || !item.action) return
        switch (item.action) {
        case "about": desktop.showAbout(); break
        case "menu": desktop.openSpotlight("menu"); break
        case "theme": desktop.openSpotlight("theme"); break
        case "background": Theme.nextBackground(); break
        case "restart": desktop.systemRestart(); break
        case "shutdown": desktop.systemShutdown(); break
        case "minimize": desktop.minimizeFocused(); break
        case "quit": desktop.quitFocusedApp(); break
        case "terminal": desktop.launch("/usr/bin/foot"); break
        case "clock": desktop.launch("/usr/bin/myapp"); break
        case "browser": desktop.launch("/usr/bin/chromium"); break
        case "firefox": desktop.launch("/usr/bin/firefox"); break
        case "remote": desktop.launch("/usr/bin/remmina"); break
        case "chatgpt": desktop.launch("/usr/bin/chatgpt"); break
        case "claude": desktop.launch("/usr/bin/claude-web"); break
        case "claudecode": desktop.launch("/usr/bin/claude-code"); break
        case "codex": desktop.launch("/usr/bin/codex"); break
        case "close": desktop.closeFocused(); break
        case "zoom": if (desktop.focusedWindow) desktop.focusedWindow.zoom(); break
        case "fullscreen": if (desktop.focusedWindow) desktop.focusedWindow.toggleFullscreen(); break
        case "float": if (desktop.focusedWindow) desktop.setFloating(desktop.focusedWindow, desktop.focusedWindow.tiled); break
        case "tiling": desktop.toggleTiling(); break
        case "keys": desktop.showKeys(); break
        case "cycle": desktop.cycleWindows(); break
        case "screenshot": desktop.screenshot(); break
        case "titlebars": Theme.setTitleBars(Theme.titleBars === "auto" ? "always" : Theme.titleBars === "always" ? "never" : "auto"); break
        case "window": desktop.activateWindow(item.win); break
        }
    }

    GlassPanel { anchors.fill: parent; backdrop: bar.backdrop; radius: 0; tint: Theme.barTint; dim: Theme.isLight ? 0 : 0.35; borderColor: "transparent"; blurAmount: 0.6; solid: false }

    Row {
        id: titles
        anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
        spacing: 0
        Repeater {
            model: bar.menus
            Item {
                id: titleItem
                property bool open: bar.openIndex === index
                width: titleText.width + Theme.px(22); height: bar.height
                Rectangle { anchors.fill: parent; anchors.topMargin: 3; anchors.bottomMargin: 3; radius: Theme.px(6); color: titleItem.open ? "#44ffffff" : "transparent" }
                Text {
                    id: titleText
                    anchors.centerIn: parent; anchors.verticalCenterOffset: Theme.px(2)   // text reads centred a little below the middle
                    text: modelData.title; color: Theme.text
                    font.pixelSize: modelData.logo ? Theme.fpx(16) : Theme.fpx(13); font.bold: !!modelData.bold; font.family: Theme.uiFont
                }
                MouseArea {
                    anchors.fill: parent; hoverEnabled: true
                    onPressed: { if (titleItem.open) bar.openIndex = -1; else bar.openAt(index, titleItem) }
                    onEntered: if (bar.openIndex >= 0 && !titleItem.open) bar.openAt(index, titleItem)
                }
            }
        }
    }
    // Workspaces (Omarchy-style): occupied ones and the current one, click to switch
    Row {
        anchors.horizontalCenter: parent.horizontalCenter; anchors.verticalCenter: parent.verticalCenter; spacing: Theme.px(4)
        Repeater {
            model: bar.desktop ? bar.desktop.workspaces : 0
            Rectangle {
                readonly property bool current: bar.desktop.workspace === index + 1
                visible: current || (bar.desktop.windowsRevision, bar.desktop.workspaceOccupied(index + 1))
                width: Theme.px(18); height: Theme.px(14); radius: Theme.px(4)
                color: current ? Theme.accent : "#33808080"
                Text { anchors.centerIn: parent; anchors.verticalCenterOffset: 1; text: index + 1; font.pixelSize: Theme.fpx(10); font.bold: true; font.family: Theme.uiFont
                       color: current ? (Theme.isLight ? "#ffffff" : "#101014") : Theme.text }
                MouseArea { anchors.fill: parent; onClicked: bar.desktop.switchWorkspace(index + 1) }
            }
        }
    }
    property real openX: 0
    function openAt(i, item) { openX = item.mapToItem(bar, 0, 0).x; openIndex = i }

    // Keyboard layout chooser, hosted at bar level so it is hit-testable (nested popups are not).
    property real kbdRight: bar.width
    Item {
        visible: kbdIcon.open; z: 60
        x: bar.kbdRight - width; y: bar.height + Theme.px(4)
        width: Theme.px(200); height: kcol.height + Theme.px(12)
        GlassPanel { anchors.fill: parent; backdrop: bar.backdrop; radius: Theme.px(10); tint: "#a8f4f4f6"; borderColor: "#66ffffff"; saturation: 0.1 }
        Column { id: kcol; anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(6) }
            Repeater { model: Theme.layouts
                Item { width: kcol.width; height: Theme.px(26)
                    Rectangle { visible: kh.containsMouse; anchors.fill: parent; radius: Theme.px(6); color: "#2f6fe6" }
                    Text { anchors.left: parent.left; anchors.leftMargin: Theme.px(12); anchors.verticalCenter: parent.verticalCenter
                           text: (modelData.id === Theme.keyboardLayout ? "✓ " : "   ") + modelData.label + "  ·  " + modelData.badge
                           color: kh.containsMouse ? "white" : "#1c1c1e"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont }
                    MouseArea { id: kh; anchors.fill: parent; hoverEnabled: true; onClicked: { Theme.setKeyboardLayout(modelData.id); kbdIcon.open = false } }
                } } }
    }

    // The open drop-down lives at the bar level (not nested in the Row) so it is hit-testable.
    Loader {
        id: drop
        active: bar.openIndex >= 0
        x: bar.openX; y: bar.height + Theme.px(4); z: 50
        sourceComponent: dropdown
    }

    Row {
        anchors.right: parent.right; anchors.rightMargin: Theme.px(14); anchors.verticalCenter: parent.verticalCenter; spacing: Theme.px(16)
        // agent usage (Claude Code / Codex)
        Item {
            id: agentIcon
            width: Theme.px(24); height: bar.height
            Rectangle { anchors.fill: parent; anchors.topMargin: 3; anchors.bottomMargin: 3; radius: Theme.px(6); color: bar.agentOpen ? "#44ffffff" : "transparent" }
            Repeater { model: 8; Rectangle { anchors.centerIn: parent; anchors.verticalCenterOffset: Theme.px(1); width: Theme.px(2.4); height: Theme.px(14); radius: width / 2; color: Theme.text; rotation: index * 22.5 } }
            MouseArea { anchors.fill: parent; onPressed: { bar.openIndex = -1; bar.displayOpen = false; kbdIcon.open = false; bar.agentOpen = !bar.agentOpen } }
        }
        // keyboard layout badge + chooser
        Item {
            id: kbdIcon
            width: kbdText.width + Theme.px(12); height: bar.height
            property bool open: false
            Rectangle { anchors.fill: parent; anchors.topMargin: 3; anchors.bottomMargin: 3; radius: Theme.px(6); color: kbdIcon.open ? "#44ffffff" : "transparent" }
            Text { id: kbdText; anchors.centerIn: parent; anchors.verticalCenterOffset: Theme.px(2); color: Theme.text; font.pixelSize: Theme.fpx(12); font.bold: true; font.family: Theme.uiFont
                   text: (Theme.layouts.find(l => l.id === Theme.keyboardLayout) || Theme.layouts[0]).badge }
            MouseArea { anchors.fill: parent; onPressed: { bar.openIndex = -1; bar.displayOpen = false; bar.kbdRight = kbdIcon.mapToItem(bar, kbdIcon.width, 0).x; kbdIcon.open = !kbdIcon.open } }
        }
        // display settings icon (monitor)
        Item {
            id: dispIcon
            width: Theme.px(22); height: bar.height
            Rectangle { anchors.fill: parent; anchors.topMargin: 3; anchors.bottomMargin: 3; radius: Theme.px(6); color: bar.displayOpen ? "#44ffffff" : "transparent" }
            Item { anchors.centerIn: parent; anchors.verticalCenterOffset: Theme.px(1); width: Theme.px(18); height: Theme.px(16)
                Rectangle { x: 0; y: 0; width: Theme.px(18); height: Theme.px(12); radius: 2; color: "transparent"; border.color: Theme.text; border.width: 1.5 }
                Rectangle { x: Theme.px(7); y: Theme.px(12); width: Theme.px(4); height: Theme.px(2); color: Theme.text }
                Rectangle { x: Theme.px(4); y: Theme.px(14); width: Theme.px(10); height: 1.5; color: Theme.text } }
            MouseArea { anchors.fill: parent; onPressed: { bar.openIndex = -1; bar.displayOpen = !bar.displayOpen } }
        }
        Text { id: clock; anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: Theme.px(2); color: Theme.text; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont
            text: Qt.formatDateTime(new Date(), "ddd d MMM  HH:mm")
            Timer { interval: 1000; running: true; repeat: true; onTriggered: clock.text = Qt.formatDateTime(new Date(), "ddd d MMM  HH:mm") } }
    }

    Component {
        id: dropdown
        Item {
            id: dd
            property var entries: (bar.desktop ? bar.desktop.windowsRevision : 0, bar.openIndex >= 0 ? bar.itemsFor(bar.openIndex) : [])
            width: Theme.px(230); height: col.height + Theme.px(12)
            GlassPanel { anchors.fill: parent; backdrop: bar.backdrop; radius: Theme.px(10); tint: "#a8f4f4f6"; borderColor: "#66ffffff"; saturation: 0.1 }
            Rectangle { anchors.fill: parent; radius: 10; color: "transparent"; border.color: "#22000000"; border.width: 1 }
            Column {
                id: col
                anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(6) }
                Repeater {
                    model: dd.entries
                    Item {
                        width: col.width
                        height: modelData.sep ? Theme.px(9) : Theme.px(26)
                        Rectangle { visible: !!modelData.sep; anchors.centerIn: parent; width: parent.width - 8; height: 1; color: "#26000000" }
                        Rectangle {
                            visible: !modelData.sep && hov.containsMouse && !modelData.disabled
                            anchors.fill: parent; radius: 6; color: Theme.accent
                        }
                        Text {
                            visible: !modelData.sep
                            anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label || ""; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont
                            color: modelData.disabled ? "#8a8a8e" : (hov.containsMouse ? "white" : "#1c1c1e")
                            elide: Text.ElideRight; width: parent.width - 80
                        }
                        Text {
                            visible: !modelData.sep && !!modelData.shortcut
                            anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                            text: modelData.shortcut || ""; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont
                            color: hov.containsMouse && !modelData.disabled ? "white" : "#6e6e73"
                        }
                        MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; enabled: !modelData.sep && !modelData.disabled
                                    onClicked: bar.activate(modelData) }
                    }
                }
            }
        }
    }
}
