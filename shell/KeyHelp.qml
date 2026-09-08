import QtQuick
import MyShell

// ⌘K: all keybindings, Omarchy-style cheat sheet. Esc / click closes.
Item {
    id: kh
    property Item backdrop
    property var bindings: []
    anchors.fill: parent
    z: 28
    focus: visible
    onVisibleChanged: { if (visible) { kh.forceActiveFocus(); if (desktop && desktop.compositor) desktop.compositor.defaultSeat.keyboardFocus = null } else if (desktop && desktop.focusedWindow) desktop.focusedWindow.raise() }
    property var desktop
    Keys.onPressed: (ev) => { if (ev.key === Qt.Key_Escape || ev.key === Qt.Key_K) { kh.visible = false; ev.accepted = true } }
    MouseArea { anchors.fill: parent; onPressed: kh.visible = false }
    Rectangle { anchors.fill: parent; color: "#33000000" }
    Item {
        width: Theme.px(760); height: grid.height + Theme.px(56)
        anchors.centerIn: parent
        GlassPanel { anchors.fill: parent; backdrop: kh.backdrop; radius: Theme.px(18); tint: "#c81c1c22"; borderColor: "#55ffffff"; saturation: 0.15; dim: 0.25 }
        Text { x: Theme.px(24); y: Theme.px(18); text: "Keybindings"; color: "#f2f2f5"; font.pixelSize: Theme.fpx(18); font.family: Theme.uiFont; font.bold: true }
        Text { anchors.right: parent.right; anchors.rightMargin: Theme.px(24); y: Theme.px(22); text: "⌘ is the Option key on a Mac keyboard (GRAB=full: the Cmd key)"; color: "#8f8f96"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont }
        Flow {
            id: grid
            x: Theme.px(24); y: Theme.px(52); width: parent.width - Theme.px(48); spacing: Theme.px(18)
            Repeater { model: kh.bindings
                Column { width: (grid.width - Theme.px(18)) / 2; spacing: Theme.px(4)
                    Text { text: modelData.group.toUpperCase(); color: "#9a9aa2"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont; font.bold: true; font.letterSpacing: 1; bottomPadding: Theme.px(4) }
                    Repeater { model: modelData.keys
                        Item { width: parent.width; height: Theme.px(24)
                            Rectangle { width: kt.width + Theme.px(14); height: Theme.px(20); radius: Theme.px(5); color: "#2a2a30"; border.color: "#3a3a42"; anchors.verticalCenter: parent.verticalCenter
                                Text { id: kt; anchors.centerIn: parent; text: modelData[0]; color: "#e6e6ea"; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont } }
                            Text { x: Theme.px(150); anchors.verticalCenter: parent.verticalCenter; text: modelData[1]; color: "#d0d0d6"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont } } } } }
        }
    }
}
