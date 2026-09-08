import QtQuick
import MyShell

// Popover with display settings (brightness, text size, scale), Omarchy-style.
Item {
    id: panel
    property Item backdrop
    width: Theme.px(360); height: col.height + Theme.px(40)

    GlassPanel { anchors.fill: parent; backdrop: panel.backdrop; radius: Theme.px(14); tint: "#c0202126"; borderColor: "#55ffffff"; saturation: 0.1; dim: 0.2 }

    component Label: Text { color: "#c9c9ce"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont; font.bold: true; font.letterSpacing: 1 }
    component Value: Text { color: "#e6e6ea"; font.pixelSize: Theme.fpx(11); font.family: Theme.monoFont }
    component Slider: Item {
        id: sl
        property real from: 0; property real to: 1; property real value: 0; property real step: 0
        property int ticks: 0
        signal moved(real v)
        width: parent.width; height: Theme.px(22)
        function setFromX(px) {
            let t = Math.max(0, Math.min(1, (px - knob.width / 2) / (width - knob.width)))
            let v = from + t * (to - from)
            if (step > 0) v = Math.round(v / step) * step
            v = Math.max(from, Math.min(to, v)); value = v; moved(v)
        }
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: Theme.px(5); radius: height / 2; color: "#4a4a52" }
        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: knob.x + knob.width / 2; height: Theme.px(5); radius: height / 2; color: "#d9d9e0" }
        Row { visible: sl.ticks > 1; anchors.verticalCenter: parent.verticalCenter; width: parent.width; spacing: 0
              Repeater { model: sl.ticks; Item { width: sl.width / sl.ticks; height: Theme.px(5)
                  Rectangle { visible: index > 0; width: 2; height: parent.height; color: "#1c1c1e"; anchors.left: parent.left } } } }
        Rectangle { id: knob; width: Theme.px(18); height: width; radius: width / 2; color: "white"; border.color: "#33000000"
            anchors.verticalCenter: parent.verticalCenter
            x: (sl.value - sl.from) / (sl.to - sl.from) * (sl.width - width) }
        MouseArea { anchors.fill: parent; onPressed: (m) => sl.setFromX(m.x); onPositionChanged: (m) => { if (pressed) sl.setFromX(m.x) } }
    }

    Column {
        id: col
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(20) }
        spacing: Theme.px(14)

        Row { spacing: Theme.px(14)
            // monitor glyph
            Item { width: Theme.px(36); height: Theme.px(36)
                Rectangle { x: 0; y: Theme.px(4); width: Theme.px(36); height: Theme.px(24); radius: Theme.px(4); color: "transparent"; border.color: "#e6e6ea"; border.width: 2 }
                Rectangle { x: Theme.px(14); y: Theme.px(29); width: Theme.px(8); height: Theme.px(4); color: "#e6e6ea" }
                Rectangle { x: Theme.px(9); y: Theme.px(33); width: Theme.px(18); height: 2; color: "#e6e6ea" } }
            Column { spacing: 2
                Text { text: "Display"; color: "#f2f2f5"; font.pixelSize: Theme.fpx(18); font.family: Theme.uiFont; font.bold: true }
                Label { text: "VIRTUAL1 · 1920×1200" } }
        }
        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Item { width: parent.width; height: Theme.px(18)
            Label { text: "BRIGHTNESS"; anchors.left: parent.left }
            Value { text: Math.round(Theme.brightness * 100) + "%"; anchors.right: parent.right } }
        Slider { from: 0.3; to: 1.0; value: Theme.brightness; onMoved: (v) => Theme.setBrightness(v) }
        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Item { width: parent.width; height: Theme.px(18)
            Label { text: "TEXT SIZE"; anchors.left: parent.left }
            Value { text: Theme.terminalFontPt + "pt"; anchors.right: parent.right } }
        Slider { from: 8; to: 20; step: 1; ticks: 6; value: Theme.terminalFontPt
                 onMoved: (v) => { Theme.setTerminalFontPt(v); Theme.setTextScale(v / 11) } }
        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Label { text: "MAC WINDOW" }
        Row { spacing: Theme.px(8)
            Repeater { model: [ { t: "Fill", c: "fit" }, { t: "Center", c: "center" }, { t: "Full screen", c: "fullscreen" }, { t: "1:1", c: "native" } ]
                Rectangle {
                    width: (col.width - Theme.px(8) * 3) / 4; height: Theme.px(34); radius: Theme.px(6)
                    color: mb.pressed ? "#4d4d58" : "#2a2a30"; border.color: "#3a3a42"
                    Text { anchors.centerIn: parent; text: modelData.t; color: "#e6e6ea"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont }
                    MouseArea { id: mb; anchors.fill: parent; onClicked: Launcher.hostCommand(modelData.c) }
                } } }
        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Label { text: "SCALE" }
        Row { spacing: Theme.px(8)
            Repeater { model: [1, 1.25, 1.5, 2, 2.5]
                Rectangle {
                    width: (col.width - Theme.px(8) * 4) / 5; height: Theme.px(34); radius: Theme.px(6)
                    property bool current: Math.abs(Theme.scale - modelData) < 0.01
                    color: current ? "#4d4d58" : "#2a2a30"; border.color: current ? "#9a9aa8" : "#3a3a42"
                    Text { anchors.centerIn: parent; text: modelData + "x"; color: "#e6e6ea"; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont }
                    MouseArea { anchors.fill: parent; onClicked: Theme.setScale(modelData) }
                } } }
    }
}
