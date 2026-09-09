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
    property var desktop
    // Two tabs: the cheat sheet (grid by group) and a compact searchable list (Omarchy's keybindings view).
    property string tab: "sheet"
    property string query: ""
    function flat() {
        let out = []
        for (const g of bindings) for (const k of g.keys) out.push({ group: g.group, key: k[0], desc: k[1] })
        return out
    }
    readonly property var hits: {
        const q = query.trim().toLowerCase()
        return flat().filter(b => q === "" || (b.key + " " + b.desc + " " + b.group).toLowerCase().indexOf(q) >= 0)
    }
    function showSearch(seed) { tab = "search"; query = seed || ""; search.text = query; search.forceActiveFocus() }
    function showSheet() { tab = "sheet"; query = ""; search.text = ""; kh.forceActiveFocus() }
    onVisibleChanged: { if (visible) { showSheet(); if (desktop && desktop.compositor) desktop.compositor.defaultSeat.keyboardFocus = null } else if (desktop && desktop.focusedWindow) desktop.focusedWindow.raise() }
    Keys.onPressed: (ev) => {
        if (ev.key === Qt.Key_Escape || ev.key === Qt.Key_K) { kh.visible = false; ev.accepted = true }
        else if (ev.key === Qt.Key_Tab) { showSearch(""); ev.accepted = true }
        else if (ev.text.length && ev.text.charCodeAt(0) >= 32 && !(ev.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))) { showSearch(ev.text); ev.accepted = true }   // just start typing
    }
    MouseArea { anchors.fill: parent; onPressed: kh.visible = false }
    // Held modifiers (from the C++ key filter) highlight the bindings that start with exactly them.
    readonly property int held: KeyGrab.modifiers
    function modsOf(k) {
        let m = 0
        if (k.indexOf("⌘") >= 0) m |= Qt.MetaModifier
        if (k.indexOf("⇧") >= 0) m |= Qt.ShiftModifier
        if (k.indexOf("⌥") >= 0) m |= Qt.AltModifier
        if (k.indexOf("^") >= 0 || k.indexOf("⌃") >= 0) m |= Qt.ControlModifier
        return m
    }
    Item {
        width: Theme.px(760); height: (kh.tab === "sheet" ? grid.height : searchBox.height) + Theme.px(56)
        anchors.centerIn: parent
        GlassPanel { anchors.fill: parent; backdrop: kh.backdrop; radius: Theme.px(18); tint: "#ee1c1c22"; borderColor: "#55ffffff"; saturation: 0.15; dim: 0.25 }
        Text { x: Theme.px(24); y: Theme.px(18); text: "Keybindings"; color: "#f2f2f5"; font.pixelSize: Theme.fpx(18); font.family: Theme.uiFont; font.bold: true }
        Row { x: Theme.px(150); y: Theme.px(17); spacing: Theme.px(4)
            Repeater { model: [ { id: "sheet", label: "Sheet" }, { id: "search", label: "Search  ⇥" } ]
                Rectangle { width: tl.width + Theme.px(18); height: Theme.px(24); radius: Theme.px(6)
                    color: kh.tab === modelData.id ? "#3a3a44" : "transparent"; border.color: kh.tab === modelData.id ? "#55ffffff" : "#33ffffff"
                    Text { id: tl; anchors.centerIn: parent; text: modelData.label; color: kh.tab === modelData.id ? "#ffffff" : "#9a9aa2"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; font.bold: kh.tab === modelData.id }
                    MouseArea { anchors.fill: parent; onClicked: modelData.id === "sheet" ? kh.showSheet() : kh.showSearch("") } } } }
        Text { anchors.right: parent.right; anchors.rightMargin: Theme.px(24); y: Theme.px(22); width: parent.width - Theme.px(330)
               horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft
               text: kh.held ? "Showing the bindings of the keys you hold" : "⌘ = Option key (GRAB=full: Cmd) · hold ⌘, ⌘⇧, ⌘^ to highlight · type to search"
               color: kh.held ? "#e6e6ea" : "#8f8f96"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont }
        // ---- search tab: field + compact list ----
        Column {
            id: searchBox
            visible: kh.tab === "search"
            x: Theme.px(24); y: Theme.px(52); width: parent.width - Theme.px(48); spacing: Theme.px(8)
            Rectangle { width: parent.width; height: Theme.px(36); radius: Theme.px(8); color: "#33ffffff"; border.color: "#33ffffff"
                Text { anchors.left: parent.left; anchors.leftMargin: Theme.px(12); anchors.verticalCenter: parent.verticalCenter; text: "⌕"; color: "#c9c9ce"; font.pixelSize: Theme.fpx(16) }
                TextInput { id: search; anchors { left: parent.left; right: parent.right; leftMargin: Theme.px(36); rightMargin: Theme.px(12); verticalCenter: parent.verticalCenter }
                    color: "white"; font.pixelSize: Theme.fpx(15); font.family: Theme.uiFont; selectByMouse: true
                    onTextChanged: kh.query = text
                    Keys.onPressed: (ev) => {
                        if (ev.key === Qt.Key_Escape) { if (text.length) text = ""; else kh.visible = false; ev.accepted = true }
                        else if (ev.key === Qt.Key_Tab) { kh.showSheet(); ev.accepted = true } }
                    Text { anchors.fill: parent; visible: !search.text.length; text: "Search keybindings…"; color: "#8f8f96"; font: search.font; verticalAlignment: Text.AlignVCenter } } }
            ListView {
                width: parent.width; height: Math.min(contentHeight, Theme.px(26) * 16); clip: true; interactive: contentHeight > height
                model: kh.hits
                delegate: Item { id: srow; width: ListView.view.width; height: Theme.px(26)
                    readonly property bool hit: kh.held !== 0 && kh.modsOf(modelData.key) === kh.held
                    opacity: kh.held !== 0 && !hit ? 0.35 : 1
                    Rectangle { x: 0; width: Theme.px(170); height: Theme.px(20); radius: Theme.px(5); anchors.verticalCenter: parent.verticalCenter
                        color: srow.hit ? Theme.accent : "#2a2a30"; border.color: srow.hit ? Qt.lighter(Theme.accent, 1.3) : "#3a3a42"
                        Text { anchors.centerIn: parent; text: modelData.key; color: srow.hit ? "#ffffff" : "#e6e6ea"; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont; elide: Text.ElideRight; width: parent.width - 8; horizontalAlignment: Text.AlignHCenter } }
                    Text { x: Theme.px(184); anchors.verticalCenter: parent.verticalCenter; text: modelData.desc; color: "#d0d0d6"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont }
                    Text { anchors.right: parent.right; anchors.rightMargin: Theme.px(6); anchors.verticalCenter: parent.verticalCenter; text: modelData.group; color: "#6e6e78"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont } }
                Text { visible: kh.hits.length === 0; anchors.centerIn: parent; text: "No matching keybinding"; color: "#8f8f96"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont }
            }
        }
        // ---- sheet tab: grid by group ----
        Flow {
            id: grid
            visible: kh.tab === "sheet"
            x: Theme.px(24); y: Theme.px(52); width: parent.width - Theme.px(48); spacing: Theme.px(18)
            Repeater { model: kh.bindings
                Column { width: (grid.width - Theme.px(18)) / 2; spacing: Theme.px(4)
                    Text { text: modelData.group.toUpperCase(); color: "#9a9aa2"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont; font.bold: true; font.letterSpacing: 1; bottomPadding: Theme.px(4) }
                    Repeater { model: modelData.keys
                        Item { id: row; width: parent.width; height: Theme.px(24)
                            readonly property int mods: kh.modsOf(modelData[0])
                            readonly property bool hit: kh.held !== 0 && mods === kh.held
                            readonly property bool dimmed: kh.held !== 0 && !hit
                            opacity: dimmed ? 0.35 : 1
                            Behavior on opacity { NumberAnimation { duration: 80 } }
                            Rectangle { width: kt.width + Theme.px(14); height: Theme.px(20); radius: Theme.px(5); anchors.verticalCenter: parent.verticalCenter
                                color: row.hit ? Theme.accent : "#2a2a30"; border.color: row.hit ? Qt.lighter(Theme.accent, 1.3) : "#3a3a42"
                                Text { id: kt; anchors.centerIn: parent; text: modelData[0]; color: row.hit ? "#ffffff" : "#e6e6ea"; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont; font.bold: row.hit } }
                            Text { x: Theme.px(150); anchors.verticalCenter: parent.verticalCenter; text: modelData[1]; color: row.hit ? "#ffffff" : "#d0d0d6"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont; font.bold: row.hit } } } } }
        }
    }
}
