import QtQuick
import MyShell

// macOS-style app icon: rounded gradient plate with an inner highlight and a per-app glyph
// (assets/icons/<kind>.svg, or the real browser icon from the apps disk). `kind` selects the artwork.
Item {
    id: icon
    property string kind: "terminal"
    property real size: 52
    width: size; height: size

    // plate colours (top, bottom) per app; the clock keeps its white face
    readonly property var plates: ({
        terminal:   ["#8d6ffb", "#5a3fd6"], chatgpt:  ["#25b78d", "#0e8c69"],
        claude:     ["#e98661", "#c95f3b"], claudecode: ["#e98661", "#c95f3b"],
        codex:      ["#3b3b42", "#1d1d21"], firefox:  ["#7043dc", "#3a1e88"],
        chromium:   ["#3f8dff", "#1a5bd4"], remote:   ["#4fb3a6", "#227a70"], clock: ["#ffffff", "#e9e9ee"] })
    readonly property var plate: plates[kind] || plates.terminal

    Rectangle {
        id: plateRect
        anchors.fill: parent
        radius: width * 0.225
        gradient: Gradient {
            GradientStop { position: 0.0; color: icon.plate[0] }
            GradientStop { position: 1.0; color: icon.plate[1] }
        }
        border.color: "#33000000"; border.width: 1
        // top highlight
        Rectangle {
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 1 }
            height: parent.height * 0.5; radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#40ffffff" }
                GradientStop { position: 1.0; color: "#00ffffff" }
            }
        }
    }

    // ---- glyph: assets/icons/<kind>.svg (transparent, 100x100 viewBox) ----
    Image {
        visible: icon.kind !== "clock" && !realIcon.visible
        anchors.fill: parent
        source: icon.kind === "clock" ? "" : "assets/icons/" + icon.kind + ".svg"
        sourceSize: Qt.size(icon.size * 2, icon.size * 2); smooth: true; mipmap: true
    }
    // ---- browsers: the real icon from the apps disk (Debian's hicolor set) once it is installed ----
    Image {
        id: realIcon
        visible: status === Image.Ready
        anchors.centerIn: parent; width: icon.size * 0.72; height: width
        source: icon.kind === "chromium" ? "file:///mnt/apps/usr/share/icons/hicolor/256x256/apps/chromium.png"
              : icon.kind === "firefox" ? "file:///mnt/apps/usr/share/icons/hicolor/128x128/apps/firefox-esr.png" : ""
        sourceSize: Qt.size(icon.size * 2, icon.size * 2); smooth: true; mipmap: true
    }

    // ---- clock: live analogue face ----
    Item {
        id: face
        visible: icon.kind === "clock"
        anchors.fill: parent
        property date now: new Date()
        Timer { interval: 1000; running: icon.kind === "clock"; repeat: true; onTriggered: face.now = new Date() }
        Rectangle { // face
            anchors.centerIn: parent; width: icon.size * 0.78; height: width; radius: width / 2
            color: "#ffffff"; border.color: "#c8c8cc"; border.width: 1
            Repeater { // hour ticks
                model: 12
                Rectangle {
                    id: tick
                    property real faceR: parent.width / 2
                    width: index % 3 === 0 ? 2 : 1; height: index % 3 === 0 ? icon.size * 0.08 : icon.size * 0.05
                    color: "#333"; antialiasing: true
                    x: faceR - width / 2; y: 2
                    transform: Rotation { origin.x: tick.width / 2; origin.y: tick.faceR - 2; angle: index * 30 }
                }
            }
        }
        Item { // hands
            anchors.centerIn: parent; width: 0; height: 0
            Rectangle { // hour
                id: hourHand
                width: 2.5; height: icon.size * 0.20; radius: 1; color: "#222"; antialiasing: true
                x: -width / 2; y: -height + 1
                transform: Rotation { origin.x: hourHand.width / 2; origin.y: hourHand.height - 1; angle: (face.now.getHours() % 12) * 30 + face.now.getMinutes() * 0.5 }
            }
            Rectangle { // minute
                id: minuteHand
                width: 2; height: icon.size * 0.30; radius: 1; color: "#222"; antialiasing: true
                x: -width / 2; y: -height + 1
                transform: Rotation { origin.x: minuteHand.width / 2; origin.y: minuteHand.height - 1; angle: face.now.getMinutes() * 6 }
            }
            Rectangle { // second
                id: secondHand
                width: 1; height: icon.size * 0.32; color: "#ff9500"; antialiasing: true
                x: -width / 2; y: -height + 1
                transform: Rotation { origin.x: secondHand.width / 2; origin.y: secondHand.height - 1; angle: face.now.getSeconds() * 6 }
            }
            Rectangle { width: 4; height: 4; radius: 2; color: "#ff9500"; x: -2; y: -2 }
        }
    }
}
