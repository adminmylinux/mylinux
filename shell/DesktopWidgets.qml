import QtQuick
import MyShell

// Desktop overlay drawn on the wallpaper, under every window: the date in large type, a month calendar
// with today marked, the time, and the current weather (Weather singleton). Purely visual: no mouse
// handling, so clicks go through to the desktop. Toggled with Theme.desktopWidgets (Style menu).
Item {
    id: dw
    property date now: new Date()
    Timer { interval: 1000; running: dw.visible; repeat: true; onTriggered: dw.now = new Date() }
    readonly property color ink: "#f4f4f6"
    readonly property color inkDim: "#d0d0d6"
    component Shadowed: Text { color: dw.ink; font.family: Theme.uiFont; style: Text.Outline; styleColor: "#66000000" }

    // ---- date, right of centre ----
    Column {
        id: dateBlock
        anchors.right: weatherBlock.left; anchors.rightMargin: Theme.px(36)
        anchors.top: parent.top; anchors.topMargin: Theme.px(110)
        spacing: 0
        Shadowed { anchors.right: parent.right; text: dw.now.getDate(); font.pixelSize: Theme.fpx(190); font.weight: Font.Light; lineHeight: 0.8 }
        Shadowed { anchors.right: parent.right; text: Qt.formatDate(dw.now, "MMMM yyyy"); font.pixelSize: Theme.fpx(34); font.weight: Font.Light }
        Shadowed { anchors.right: parent.right; text: "Today's " + Qt.formatDate(dw.now, "dddd"); font.pixelSize: Theme.fpx(22); color: dw.inkDim }
    }

    // ---- weather + clock, right edge ----
    Column {
        id: weatherBlock
        anchors.right: parent.right; anchors.rightMargin: Theme.px(90)
        anchors.top: parent.top; anchors.topMargin: Theme.px(120)
        spacing: Theme.px(4)
        Row { spacing: Theme.px(18)
            // sun / moon / cloud / rain glyphs drawn from the WMO code; moon at night
            Shadowed { text: !Weather.ok ? "" : (Weather.code >= 61 && Weather.code <= 82) || (Weather.code >= 95) ? "☂" : (Weather.code >= 71 && Weather.code <= 86) ? "❄" : Weather.code >= 45 ? "≋" : Weather.code >= 2 ? "☁" : (Weather.isDay ? "☀" : "☾")
                       font.pixelSize: Theme.fpx(64); anchors.verticalCenter: parent.verticalCenter }
            Shadowed { text: Weather.ok ? Weather.temperature + "°" : ""; font.pixelSize: Theme.fpx(72); font.weight: Font.Light; anchors.verticalCenter: parent.verticalCenter }
        }
        Shadowed { text: Weather.ok ? Weather.city : (Weather.error.length ? "Weather unavailable" : ""); font.pixelSize: Theme.fpx(20); color: dw.inkDim }
        Shadowed { text: Weather.ok ? Weather.condition : ""; font.pixelSize: Theme.fpx(26) }
        Shadowed { text: Weather.ok ? "Feels like " + Weather.feelsLike + Weather.unit : ""; font.pixelSize: Theme.fpx(18); color: dw.inkDim }
        Item { width: 1; height: Theme.px(10) }
        Shadowed { text: Qt.formatTime(dw.now, "HH:mm"); font.pixelSize: Theme.fpx(48); font.weight: Font.Light }
    }

    // ---- month calendar, left of centre ----
    Column {
        id: cal
        anchors.right: dateBlock.left; anchors.rightMargin: Theme.px(120)
        anchors.top: parent.top; anchors.topMargin: Theme.px(130)
        spacing: Theme.px(6)
        readonly property int year: dw.now.getFullYear()
        readonly property int month: dw.now.getMonth()
        readonly property int first: new Date(year, month, 1).getDay()          // 0 = Sunday
        readonly property int days: new Date(year, month + 1, 0).getDate()
        Shadowed { text: Qt.formatDate(dw.now, "MMMM"); color: "#ff6b57"; font.pixelSize: Theme.fpx(18); font.bold: true }
        Row { spacing: 0
            Repeater { model: ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
                Shadowed { width: Theme.px(26); horizontalAlignment: Text.AlignHCenter; text: modelData; font.pixelSize: Theme.fpx(11); font.bold: true; color: dw.inkDim } } }
        Grid { columns: 7; rowSpacing: Theme.px(2); columnSpacing: 0
            Repeater { model: cal.first + cal.days
                Item { width: Theme.px(26); height: Theme.px(20)
                    readonly property int day: index - cal.first + 1
                    readonly property bool today: day === dw.now.getDate()
                    Rectangle { visible: parent.today; anchors.centerIn: parent; width: Theme.px(22); height: Theme.px(18); radius: Theme.px(4); color: "#ff6b57" }
                    Shadowed { anchors.centerIn: parent; visible: parent.day >= 1; text: parent.day; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont; color: parent.today ? "white" : (parent.day < dw.now.getDate() ? "#9a9aa2" : dw.ink) } } } }
    }
}
