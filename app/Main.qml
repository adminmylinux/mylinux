import QtQuick

Window {
    id: root
    visible: true
    width: 520; height: 340
    visibility: Qt.platform.pluginName === "wayland" ? Window.Windowed : Window.FullScreen
    color: "#101418"
    title: "mylinux"

    property int clicks: 0

    Column {
        anchors.centerIn: parent
        spacing: 24

        Text {
            id: clock
            anchors.horizontalCenter: parent.horizontalCenter
            color: "#e6edf3"
            font.pixelSize: Math.min(96, root.width / 5)
            font.family: "DejaVu Sans"
            text: Qt.formatTime(new Date(), "hh:mm:ss")
            Timer { interval: 1000; running: true; repeat: true
                    onTriggered: clock.text = Qt.formatTime(new Date(), "hh:mm:ss") }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: "#8b949e"
            font.pixelSize: 22
            font.family: "DejaVu Sans"
            text: "mylinux · Qt " + qtVersion + " · running from RAM"
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 260; height: 64; radius: 12
            color: mouse.pressed ? "#1f6feb" : (mouse.containsMouse ? "#388bfd" : "#238636")
            Text {
                anchors.centerIn: parent
                color: "white"; font.pixelSize: 24; font.family: "DejaVu Sans"
                text: root.clicks === 0 ? "Click me" : "Clicked " + root.clicks + "×"
            }
            MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true
                        onClicked: root.clicks++ }
        }
    }

    Text {
        anchors { right: parent.right; bottom: parent.bottom; margins: 16 }
        color: "#484f58"; font.pixelSize: 14; font.family: "DejaVu Sans"
        text: appPath + "  ·  " + Screen.width + "×" + Screen.height + "  ·  " + Qt.platform.pluginName
    }
}
