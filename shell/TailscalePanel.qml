import QtQuick
import MyShell

// Tailscale popover: this node's state, a Connect / Disconnect button, and every peer of the tailnet
// with online dot, name, IP and OS. Click a peer to open a terminal with ssh to it.
Item {
    id: panel
    property Item backdrop
    property var desktop
    width: Theme.px(420); height: col.height + Theme.px(36)
    onVisibleChanged: Tailscale.active = visible

    GlassPanel { anchors.fill: parent; backdrop: panel.backdrop; radius: Theme.px(14); tint: "#cc1b1b22"; borderColor: "#55ffffff"; saturation: 0.1; dim: 0.25 }

    component Label: Text { color: "#9a9aa2"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont; font.bold: true; font.letterSpacing: 1 }
    component Mono: Text { color: "#e6e6ea"; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont }
    function stateText() {
        switch (Tailscale.state) {
        case "Running": return "CONNECTED" + (Tailscale.tailnet ? " · " + Tailscale.tailnet.toUpperCase() : "")
        case "NeedsLogin": return "NOT LOGGED IN"
        case "Stopped": return "DISCONNECTED"
        case "Starting": return "CONNECTING…"
        case "": return Tailscale.available ? "DAEMON NOT RUNNING" : "NOT INSTALLED"
        default: return Tailscale.state.toUpperCase()
        }
    }

    Column {
        id: col
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(18) }
        spacing: Theme.px(10)

        Row { width: parent.width; spacing: Theme.px(12)
            Item { width: Theme.px(34); height: Theme.px(34); anchors.verticalCenter: parent.verticalCenter
                Grid { anchors.centerIn: parent; columns: 3; spacing: Theme.px(3)
                    Repeater { model: 9
                        Rectangle { width: Theme.px(8); height: width; radius: width / 2
                                    color: Tailscale.connected ? "#f2f2f5" : "#6e6e78"
                                    opacity: (index === 4 || index >= 6) ? 1 : 0.35 } } } }
            Column { spacing: 2; anchors.verticalCenter: parent.verticalCenter; width: parent.width - Theme.px(34) - Theme.px(12) - btn.width - Theme.px(12)
                Text { text: Tailscale.connected && Tailscale.selfName ? Tailscale.selfName : "Tailscale"; color: "#f2f2f5"; font.pixelSize: Theme.fpx(17); font.family: Theme.uiFont; font.bold: true }
                Label { text: panel.stateText() + (Tailscale.selfIp ? "  ·  " + Tailscale.selfIp : "") } }
            Rectangle { id: btn; anchors.verticalCenter: parent.verticalCenter; width: btnText.width + Theme.px(22); height: Theme.px(28); radius: Theme.px(8)
                color: Tailscale.connected ? "#3a3a44" : Theme.accent
                Text { id: btnText; anchors.centerIn: parent; text: Tailscale.connected ? "Disconnect" : "Connect"; color: "white"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; font.bold: true }
                MouseArea { anchors.fill: parent; onClicked: Tailscale.connected ? Tailscale.disconnect() : Tailscale.connectNow() } }
        }

        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Label { text: Tailscale.peers.length ? "MACHINES  ·  " + Tailscale.onlineCount + " ONLINE OF " + Tailscale.peers.length : (Tailscale.connected ? "NO OTHER MACHINES" : "CONNECT TO SEE YOUR MACHINES") }
        ListView {
            width: parent.width; height: Math.min(contentHeight, Theme.px(30) * 12); clip: true; interactive: contentHeight > height
            model: Tailscale.peers
            delegate: Rectangle { width: ListView.view.width; height: Theme.px(30); radius: Theme.px(6); color: rowMa.containsMouse ? "#22ffffff" : "transparent"
                Rectangle { x: Theme.px(8); anchors.verticalCenter: parent.verticalCenter; width: Theme.px(8); height: width; radius: width / 2
                            color: modelData.online ? "#34c759" : "#55ffffff" }
                Text { x: Theme.px(24); anchors.verticalCenter: parent.verticalCenter; text: modelData.name; color: modelData.online ? "#f2f2f5" : "#9a9aa2"
                       font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont; font.weight: Font.Medium; elide: Text.ElideRight; width: Theme.px(150) }
                Mono { x: Theme.px(180); anchors.verticalCenter: parent.verticalCenter; text: modelData.ip; color: modelData.online ? "#e6e6ea" : "#8f8f96" }
                Text { anchors.right: parent.right; anchors.rightMargin: Theme.px(10); anchors.verticalCenter: parent.verticalCenter; text: modelData.os; color: "#6e6e78"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont }
                MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true
                    onClicked: if (panel.desktop) panel.desktop.launchArgs("/usr/bin/foot", ["-T", "ssh " + modelData.name, "apps-run", "ssh", modelData.ip]) }
            }
        }
        Label { visible: Tailscale.peers.length > 0; text: "CLICK A MACHINE FOR AN SSH TERMINAL" ; color: "#6e6e78" }
    }
}
