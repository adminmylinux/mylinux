import QtQuick
import MyShell

// macOS-style app icon drawn in QML (no image assets): rounded square, vertical gradient,
// inner highlight, and a per-app glyph. `kind` selects the artwork.
Item {
    id: icon
    property string kind: "terminal"
    property real size: 52
    width: size; height: size

    Rectangle {
        id: plate
        anchors.fill: parent
        radius: width * 0.225
        gradient: Gradient {
            GradientStop { position: 0.0; color: icon.kind === "terminal" ? "#4a4a4f" : "#ffffff" }
            // (chatgpt/claude draw their own plates on top)
            GradientStop { position: 1.0; color: icon.kind === "terminal" ? "#1b1b1e" : "#e9e9ee" }
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

    // ---- terminal: prompt glyph on a dark plate ----
    Text {
        visible: icon.kind === "terminal"
        anchors.centerIn: parent; anchors.verticalCenterOffset: -1
        text: ">_"; color: "#f2f2f2"
        font.pixelSize: icon.size * 0.40; font.bold: true; font.family: Theme.monoFont
    }

    // ---- chromium: colour ring with a blue centre ----
    Item {
        visible: icon.kind === "chromium"
        anchors.fill: parent
        Rectangle { anchors.centerIn: parent; width: icon.size * 0.72; height: width; radius: width / 2
            gradient: Gradient { orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#34a853" }
                GradientStop { position: 0.5; color: "#fbbc05" }
                GradientStop { position: 1.0; color: "#ea4335" } }
            border.color: "#22000000"; border.width: 1 }
        Rectangle { anchors.centerIn: parent; width: icon.size * 0.34; height: width; radius: width / 2; color: "#ffffff" }
        Rectangle { anchors.centerIn: parent; width: icon.size * 0.26; height: width; radius: width / 2; color: "#4285f4" }
    }

    // ---- firefox: purple plate, orange swirl ring around a blue globe ----
    Item {
        visible: icon.kind === "firefox"; anchors.fill: parent
        Rectangle { anchors.fill: parent; radius: width * 0.225
            gradient: Gradient { GradientStop { position: 0.0; color: "#6b2fbf" } GradientStop { position: 1.0; color: "#3a1a7a" } } }
        Rectangle { anchors.centerIn: parent; width: icon.size * 0.68; height: width; radius: width / 2
            gradient: Gradient { GradientStop { position: 0.0; color: "#ffd23f" } GradientStop { position: 0.55; color: "#ff7a1a" } GradientStop { position: 1.0; color: "#e0286a" } } }
        Rectangle { anchors.centerIn: parent; anchors.horizontalCenterOffset: -icon.size * 0.04; anchors.verticalCenterOffset: icon.size * 0.04
            width: icon.size * 0.40; height: width; radius: width / 2
            gradient: Gradient { GradientStop { position: 0.0; color: "#5cc5ff" } GradientStop { position: 1.0; color: "#2a63d8" } } }
        Rectangle { x: icon.size * 0.18; y: icon.size * 0.16; width: icon.size * 0.30; height: icon.size * 0.14; radius: height / 2; rotation: -30; color: "#3a1a7a" }
    }

    // ---- chatgpt: dark plate, white knot-ish glyph ----
    Item {
        visible: icon.kind === "chatgpt"; anchors.fill: parent
        Rectangle { anchors.fill: parent; radius: width * 0.225; color: "#10a37f" }
        Rectangle { anchors.centerIn: parent; width: icon.size * 0.52; height: width; radius: width / 2; color: "transparent"; border.color: "white"; border.width: icon.size * 0.09 }
        Rectangle { anchors.centerIn: parent; width: icon.size * 0.52; height: icon.size * 0.09; color: "white"; rotation: 45 }
    }
    // ---- claude: terracotta plate with a starburst ----
    Item {
        visible: icon.kind === "claude" || icon.kind === "claudecode"; anchors.fill: parent
        Rectangle { anchors.fill: parent; radius: width * 0.225; color: icon.kind === "claude" ? "#d97757" : "#2b2b2e" }
        Repeater { model: 8
            Rectangle { anchors.centerIn: parent; width: icon.size * 0.10; height: icon.size * 0.62; radius: width / 2
                        color: icon.kind === "claude" ? "#fff5ee" : "#d97757"; rotation: index * 22.5 } }
        Text { visible: icon.kind === "claudecode"; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: icon.size * 0.08
               text: ">_"; color: "white"; font.pixelSize: icon.size * 0.22; font.bold: true; font.family: Theme.monoFont }
    }

    // ---- codex: dark plate with a green prompt chevron ----
    Item {
        visible: icon.kind === "codex"; anchors.fill: parent
        Rectangle { anchors.fill: parent; radius: width * 0.225; color: "#151517"; border.color: "#33ffffff" }
        Text { anchors.centerIn: parent; text: "›_"; color: "#10a37f"; font.pixelSize: icon.size * 0.42; font.bold: true; font.family: Theme.monoFont }
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
