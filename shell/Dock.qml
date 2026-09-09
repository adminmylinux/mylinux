import QtQuick
import MyShell

Item {
    id: dock
    property var desktop
    property Item backdrop
    width: row.width + Theme.px(28); height: Theme.px(74)
    // Auto-hide: slide below the screen edge until the desktop reveals us (pointer at the bottom edge)
    readonly property bool hidden: Theme.dockAutoHide && !(desktop && desktop.dockRevealed)
    anchors.bottomMargin: hidden ? -(height + Theme.px(8)) : Theme.px(10)
    Behavior on anchors.bottomMargin { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    property alias hovered: hh.hovered
    HoverHandler { id: hh; onHoveredChanged: if (!hovered && desktop) desktop.dockLeave() }

    GlassPanel { anchors.fill: parent; backdrop: dock.backdrop; radius: Theme.px(22); tint: "#30ffffff"; borderColor: "#70ffffff"; solid: false }

    property var apps: [
        { name: "Terminal", appId: "foot",  exec: "/usr/bin/foot",  kind: "terminal" },
        { name: "Clock",    appId: "myapp", exec: "/usr/bin/myapp", kind: "clock" },
        { name: "Firefox",  appId: "firefox-esr", exec: "/usr/bin/firefox", kind: "firefox" },
        { name: "Chromium", appId: "chromium", exec: "/usr/bin/chromium", kind: "chromium" },
        { name: "Remote Desktop", appId: "org.remmina.Remmina", exec: "/usr/bin/remmina", kind: "remote" },
        { name: "ChatGPT",  appId: "chrome-chatgpt.com__-Default", exec: "/usr/bin/chatgpt", kind: "chatgpt" },
        { name: "Claude",   appId: "chrome-claude.ai__-Default", exec: "/usr/bin/claude-web", kind: "claude" },
        { name: "Claude Code", appId: "claude-code", exec: "/usr/bin/claude-code", kind: "claudecode" },
        { name: "Codex", appId: "codex", exec: "/usr/bin/codex", kind: "codex" }
    ]

    Row {
        id: row
        anchors.centerIn: parent; spacing: Theme.px(10)
        Repeater {
            model: dock.apps
            Item {
                id: slot
                width: Theme.px(58); height: Theme.px(58)
                property bool hovered: ma.containsMouse
                property bool running: desktop ? (desktop.windowsRevision, desktop.isRunning(modelData.appId)) : false
                property bool minimized: desktop ? (desktop.windowsRevision, desktop.hasMinimized(modelData.appId)) : false

                AppIcon {
                    id: art
                    kind: modelData.kind
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 3
                    size: slot.hovered ? Theme.px(66) : Theme.px(52)
                    opacity: slot.minimized && !slot.hovered ? 0.7 : 1
                    scale: ma.pressed ? 0.92 : 1
                    Behavior on size { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
                    Behavior on scale { NumberAnimation { duration: 80 } }
                }
                // tooltip label
                Rectangle {
                    visible: slot.hovered
                    anchors.bottom: art.top; anchors.bottomMargin: 10; anchors.horizontalCenter: parent.horizontalCenter
                    width: label.width + Theme.px(16); height: Theme.px(22); radius: Theme.px(6); color: "#dd2b2b2e"
                    Text { id: label; anchors.centerIn: parent; text: modelData.name; color: "white"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont }
                }
                // running indicator
                Rectangle {
                    visible: slot.running
                    width: Theme.px(5); height: Theme.px(5); radius: width / 2; color: "#333"
                    anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: -5
                }
                MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true
                            onClicked: desktop ? desktop.activateApp(modelData.appId, modelData.exec) : Launcher.launch(modelData.exec) }
            }
        }
    }
}
