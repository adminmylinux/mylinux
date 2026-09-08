import QtQuick
import MyShell

// First-boot dialog: the apps disk is blank or empty -> offer to set it up (runs apps-setup in a terminal).
Item {
    id: fr
    property Item backdrop
    property var desktop
    property bool needed: !Launcher.fileExists("/mnt/apps/etc/debian_version") || !Launcher.fileExists("/mnt/apps/usr/bin/chromium")
    property bool dismissed: false
    property bool running: false
    anchors.fill: parent
    visible: needed && !dismissed && !running
    z: 25
    Timer { interval: 15000; running: true; repeat: true
            onTriggered: { const was = fr.needed; fr.needed = !Launcher.fileExists("/mnt/apps/etc/debian_version") || !Launcher.fileExists("/mnt/apps/usr/bin/chromium"); if (!fr.needed) { fr.running = false; if (was && fr.desktop) fr.desktop.compositor.runAutostart() } } }

    Rectangle { anchors.fill: parent; color: "#33000000" }
    Item {
        width: Theme.px(560); height: box.height + Theme.px(48)
        anchors.centerIn: parent
        GlassPanel { anchors.fill: parent; backdrop: fr.backdrop; radius: Theme.px(18); tint: "#c81c1c22"; borderColor: "#55ffffff"; saturation: 0.15; dim: 0.25 }
        Column {
            id: box
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(24) }
            spacing: Theme.px(14)
            Row { spacing: Theme.px(14)
                AppIcon { kind: "clock"; size: Theme.px(48); anchors.verticalCenter: parent.verticalCenter }
                Column { spacing: 2; anchors.verticalCenter: parent.verticalCenter
                    Text { text: "Welcome to mylinux"; color: "#f2f2f5"; font.pixelSize: Theme.fpx(20); font.family: Theme.uiFont; font.bold: true }
                    Text { text: "The OS runs from RAM. Apps and your files live on the apps disk."; color: "#c9c9ce"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont } } }
            Text { width: parent.width; wrapMode: Text.WordWrap; color: "#e6e6ea"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont
                   text: "The apps disk is empty. Setting it up downloads a minimal Debian, Chromium, Claude Code and Codex (about 1 GB, a few minutes) into out/apps.img. Your home directory, logins and installed software persist there across reboots." }
            Row { spacing: Theme.px(10)
                Rectangle { width: Theme.px(200); height: Theme.px(40); radius: Theme.px(8); color: sb.pressed ? "#2f5fd0" : "#3d6de6"
                    Text { anchors.centerIn: parent; text: "Set up the apps disk"; color: "white"; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont; font.bold: true }
                    MouseArea { id: sb; anchors.fill: parent; onClicked: { fr.running = true; Launcher.launch("/usr/bin/apps-setup-window") } } }
                Rectangle { width: Theme.px(120); height: Theme.px(40); radius: Theme.px(8); color: "#2a2a30"; border.color: "#3a3a42"
                    Text { anchors.centerIn: parent; text: "Later"; color: "#e6e6ea"; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont }
                    MouseArea { anchors.fill: parent; onClicked: fr.dismissed = true } } }
            Text { text: "Later: run  apps-setup  in a terminal, or use the Setup › Install menu."; color: "#8f8f96"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont }
        }
    }
}
