import QtQuick
import QtQuick.Window
import VncView

// vncview: tabs of VNC connections plus a "Machines" tab (saved profiles and a connect form).
// F11 toggles fullscreen (the compositor then grabs every key for the remote; Ctrl+Alt+G releases).
Window {
    id: win
    width: 1280; height: 800
    visible: true
    title: tabs.currentIndex >= 0 && tabs.currentIndex < sessions.length ? sessions[tabs.currentIndex].title + " - vncview" : "vncview"
    color: "#141416"
    readonly property color accent: "#2f6fe6"
    readonly property string font: "Inter"
    property var sessions: []            // { title, host, port, session: VncSession }
    property var currentSurface: null    // the VncSurface of the shown tab (zoom controls act on it)
    property bool fullscreen: visibility === Window.FullScreen

    Component { id: sessionComp; VncSession {} }
    function connectTo(name, host, port, username, password, quality) {
        const s = sessionComp.createObject(win)
        s.quality = quality || "balanced"
        const entry = { title: name && name.length ? name : host, host: host, port: port, session: s }
        sessions = sessions.concat([entry])
        tabs.currentIndex = sessions.length - 1
        s.open(host, port, username || "", password || "")
    }
    function closeTab(i) {
        const e = sessions[i]; if (!e) return
        e.session.close(); e.session.destroy()
        sessions = sessions.slice(0, i).concat(sessions.slice(i + 1))
        tabs.currentIndex = Math.min(tabs.currentIndex, sessions.length - 1)
    }
    function toggleFullscreen() { visibility = fullscreen ? Window.Windowed : Window.FullScreen }
    Component.onCompleted: if (startHost && startHost.length) { const m = Machines.get(startName); connectTo(startName, startHost, startPort, m.username || "", startName.length ? Machines.password(startName) : "", m.quality || "balanced") }

    // ---- tab bar (hidden in fullscreen) ----
    Rectangle {
        id: bar
        visible: !win.fullscreen
        width: parent.width; height: visible ? 32 : 0; color: "#1e1e22"
        Row {
            id: tabs
            property int currentIndex: -1          // -1 = the Machines tab
            anchors.left: parent.left; anchors.leftMargin: 6; anchors.verticalCenter: parent.verticalCenter; spacing: 4
            Rectangle { width: machinesT.implicitWidth + 24; height: 24; radius: 6; color: tabs.currentIndex === -1 ? win.accent : "#2a2a30"
                Text { id: machinesT; anchors.centerIn: parent; text: "Machines"; color: "white"; font.pixelSize: 12; font.family: win.font }
                MouseArea { anchors.fill: parent; onClicked: tabs.currentIndex = -1 } }
            Repeater { model: win.sessions
                Rectangle { width: tt.implicitWidth + 44; height: 24; radius: 6; color: tabs.currentIndex === index ? win.accent : "#2a2a30"
                    Rectangle { width: 7; height: 7; radius: 3.5; anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                                color: modelData.session.state === "connected" ? "#28c840" : modelData.session.state === "connecting" ? "#febc2e" : "#ff5f57" }
                    Text { id: tt; anchors.centerIn: parent; anchors.horizontalCenterOffset: 4; text: modelData.title; color: "white"; font.pixelSize: 12; font.family: win.font }
                    Text { anchors.right: parent.right; anchors.rightMargin: 7; anchors.verticalCenter: parent.verticalCenter; text: "×"; color: "#ccc"; font.pixelSize: 14
                           MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: win.closeTab(index) } }
                    MouseArea { anchors.fill: parent; anchors.rightMargin: 20; onClicked: tabs.currentIndex = index } } }
        }
        Row { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; spacing: 10
            Text { visible: tabs.currentIndex >= 0; text: tabs.currentIndex >= 0 && win.sessions[tabs.currentIndex] ? (win.sessions[tabs.currentIndex].session.state + (win.sessions[tabs.currentIndex].session.fbWidth ? "  " + win.sessions[tabs.currentIndex].session.fbWidth + "×" + win.sessions[tabs.currentIndex].session.fbHeight : "")) : ""; color: "#9a9aa2"; font.pixelSize: 11; font.family: win.font }
            // zoom: fit / steps / real pixels; when zoomed in the view follows the pointer
            Row { id: zoomRow; visible: tabs.currentIndex >= 0 && win.currentSurface !== null; spacing: 4; anchors.verticalCenter: parent.verticalCenter
                component ZoomButton: Rectangle { property string label; property bool selected: false; signal clicked()
                    width: Math.max(26, zl.implicitWidth + 12); height: 22; radius: 5
                    color: selected ? win.accent : zm.containsMouse ? "#3a3a42" : "#2a2a30"; border.color: selected ? win.accent : "#3a3a42"
                    Text { id: zl; anchors.centerIn: parent; text: parent.label; color: "white"; font.pixelSize: 12; font.family: win.font }
                    MouseArea { id: zm; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked() } }
                ZoomButton { label: "Fit"; selected: win.currentSurface && Math.abs(win.currentSurface.zoom - 1) < 0.001; onClicked: win.currentSurface.zoom = 1 }
                ZoomButton { label: "−"; onClicked: win.currentSurface.zoomStep(-1) }
                Text { width: 44; height: 22; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
                       text: win.currentSurface ? Math.round(win.currentSurface.displayScale * 100) + "%" : ""; color: "#e6e6ea"; font.pixelSize: 12; font.family: win.font }
                ZoomButton { label: "+"; onClicked: win.currentSurface.zoomStep(1) }
                ZoomButton { label: "1:1"; selected: win.currentSurface && Math.abs(win.currentSurface.displayScale - 1) < 0.01; onClicked: win.currentSurface.zoomToPixels() }
            }
            Text { text: "F11 full screen · Ctrl+Alt+G release keys"; color: "#6e6e78"; font.pixelSize: 11; font.family: win.font }
        }
    }

    // ---- pages ----
    Item {
        anchors.top: bar.bottom; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
        Repeater { model: win.sessions
            Item { anchors.fill: parent; visible: tabs.currentIndex === index
                VncSurface { id: surf; anchors.fill: parent; session: modelData.session; focus: visible
                             onVisibleChanged: if (visible) { forceActiveFocus(); win.currentSurface = surf }
                             Component.onCompleted: { forceActiveFocus(); if (visible) win.currentSurface = surf }
                             Component.onDestruction: if (win.currentSurface === surf) win.currentSurface = null
                             Keys.onPressed: (ev) => { if (ev.key === Qt.Key_F11) { win.toggleFullscreen(); ev.accepted = true } } }
                // unknown or changed TLS certificate: show the fingerprint, trust pins it (~/.config/mylinux/vnc/certs)
                Rectangle { anchors.centerIn: parent; visible: modelData.session.state === "untrusted"; width: Math.min(parent.width - 40, 620); height: trustCol.implicitHeight + 36; radius: 10; color: "#ee1e1e22"
                    border.color: modelData.session.certChanged ? "#ff5f57" : "#44ffffff"
                    Column { id: trustCol; anchors.centerIn: parent; width: parent.width - 36; spacing: 10
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: modelData.session.certChanged ? "#ff8a84" : "white"; font.pixelSize: 15; font.bold: true; font.family: win.font
                               text: modelData.session.certChanged ? "The certificate of " + modelData.host + " has changed" : "First connection to " + modelData.host + ": trust its certificate?" }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: "#c8c8ce"; font.pixelSize: 12; font.family: win.font
                               text: (modelData.session.certChanged ? "It no longer matches the certificate you trusted. That happens when wayvnc's certificate is regenerated, or when something else answers on this address. "
                                                                    : "The server uses a self-signed certificate. ")
                                     + "Compare the fingerprint with the server's, for example:  openssl x509 -noout -fingerprint -sha256 -in ~/.config/wayvnc/tls_cert.pem" }
                        Text { width: parent.width; wrapMode: Text.WrapAnywhere; color: "#e6e6ea"; font.pixelSize: 12; font.family: "monospace"
                               text: "Name: " + (modelData.session.certName || "(none)") + "\nSHA-256: " + modelData.session.certFingerprint }
                        Row { spacing: 8
                            Rectangle { width: 150; height: 32; radius: 8; color: modelData.session.certChanged ? "#c4433c" : win.accent
                                Text { anchors.centerIn: parent; text: modelData.session.certChanged ? "Replace and connect" : "Trust and connect"; color: "white"; font.pixelSize: 13; font.bold: true; font.family: win.font }
                                MouseArea { anchors.fill: parent; onClicked: modelData.session.trustCertificate() } }
                            Rectangle { width: 90; height: 32; radius: 8; color: "#2a2a30"; border.color: "#3a3a42"
                                Text { anchors.centerIn: parent; text: "Close"; color: "#e6e6ea"; font.pixelSize: 13; font.family: win.font }
                                MouseArea { anchors.fill: parent; onClicked: win.closeTab(index) } } } } }
                // status overlay while not connected
                Rectangle { anchors.centerIn: parent; visible: modelData.session.state !== "connected" && modelData.session.state !== "untrusted"; width: Math.min(st.implicitWidth, parent.width - 80) + 40; height: st.implicitHeight + 24; radius: 10; color: "#cc1e1e22"; border.color: "#44ffffff"
                    Text { id: st; anchors.centerIn: parent; color: "#e6e6ea"; font.pixelSize: 14; font.family: win.font; horizontalAlignment: Text.AlignHCenter
                           text: modelData.session.state === "connecting" ? "Connecting to " + modelData.host + ":" + modelData.port + "…"
                               : modelData.session.state === "error" ? "Failed: " + modelData.session.error + "\n(click to retry)"
                               : "Disconnected (click to reconnect)" }
                    MouseArea { anchors.fill: parent; onClicked: { const m = Machines.get(modelData.title); modelData.session.open(modelData.host, modelData.port, m.username || "", Machines.password(modelData.title)) } } }
            } }

        // Machines page
        Item { anchors.fill: parent; visible: tabs.currentIndex === -1
            Column { anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 24; spacing: 10; width: Math.min(parent.width - 48, 560)
                Text { text: "Machines"; color: "white"; font.pixelSize: 20; font.family: win.font; font.bold: true }
                Text { text: "Saved in ~/.config/mylinux/vnc/machines.json; passwords in the secrets store. Also: vncview host[:port] in a terminal."; color: "#9a9aa2"; font.pixelSize: 12; font.family: win.font; width: parent.width; wrapMode: Text.WordWrap }
                Repeater { model: Machines.list
                    Rectangle { width: parent.width; height: 40; radius: 8; color: rowMa.containsMouse ? "#2a2a30" : "#202024"
                        Text { anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter; text: modelData.name + "   " + modelData.host + ":" + modelData.port + (modelData.username ? "   " + modelData.username : "") + "   " + modelData.quality; color: "#e6e6ea"; font.pixelSize: 13; font.family: win.font }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; onClicked: win.connectTo(modelData.name, modelData.host, modelData.port, modelData.username, Machines.password(modelData.name), modelData.quality) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; text: "remove"; color: "#9a9aa2"; font.pixelSize: 11; font.family: win.font
                               MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: Machines.remove(modelData.name) } } } }
                Item { width: 1; height: 8 }
                Text { text: "Add or edit"; color: "white"; font.pixelSize: 15; font.family: win.font; font.bold: true }
                component Field: Rectangle { property alias text: inp.text; property string placeholder; property bool secret: false; property Item next
                    width: 520; height: 32; radius: 8; color: "#2a2a30"; border.color: inp.activeFocus ? win.accent : "#3a3a42"
                    TextInput { id: inp; anchors.fill: parent; anchors.margins: 8; verticalAlignment: TextInput.AlignVCenter; color: "white"; font.pixelSize: 13; font.family: win.font; selectByMouse: true; echoMode: parent.secret ? TextInput.Password : TextInput.Normal
                                Keys.onTabPressed: if (parent.next) parent.next.forceActiveFocus()
                                Text { anchors.fill: parent; visible: !inp.text.length; text: parent.parent.placeholder; color: "#6e6e78"; font: inp.font; verticalAlignment: Text.AlignVCenter } }
                    function forceActiveFocus() { inp.forceActiveFocus() } }
                Field { id: fName; placeholder: "Name (omarchy)"; next: fHost }
                Field { id: fHost; placeholder: "Host or IP"; next: fPort }
                Field { id: fPort; placeholder: "Port (5900)"; next: fUser }
                Field { id: fUser; placeholder: "Username (wayvnc with auth; empty for password-only servers)"; next: fPass }
                Field { id: fPass; placeholder: "Password"; secret: true }
                Row { spacing: 8
                    Repeater { model: ["fast", "balanced", "best"]
                        Rectangle { width: 90; height: 28; radius: 6; color: quality.value === modelData ? win.accent : "#2a2a30"
                            Text { anchors.centerIn: parent; text: modelData; color: "white"; font.pixelSize: 12; font.family: win.font }
                            MouseArea { anchors.fill: parent; onClicked: quality.value = modelData } } }
                    Item { id: quality; property string value: "balanced" } }
                Row { spacing: 8
                    Rectangle { width: 140; height: 34; radius: 8; color: "#3d6de6"
                        Text { anchors.centerIn: parent; text: "Save & connect"; color: "white"; font.pixelSize: 13; font.family: win.font; font.bold: true }
                        MouseArea { anchors.fill: parent; onClicked: {
                            const port = parseInt(fPort.text) || 5900; if (!fHost.text.length) return
                            const name = fName.text.length ? fName.text : fHost.text
                            Machines.save(name, fHost.text, port, fUser.text, quality.value, fPass.text)
                            win.connectTo(name, fHost.text, port, fUser.text, fPass.text.length ? fPass.text : Machines.password(name), quality.value) } } }
                    Rectangle { width: 120; height: 34; radius: 8; color: "#2a2a30"; border.color: "#3a3a42"
                        Text { anchors.centerIn: parent; text: "Connect once"; color: "#e6e6ea"; font.pixelSize: 13; font.family: win.font }
                        MouseArea { anchors.fill: parent; onClicked: { if (fHost.text.length) win.connectTo(fName.text, fHost.text, parseInt(fPort.text) || 5900, fUser.text, fPass.text, quality.value) } } } }
            }
        }
    }
    Shortcut { sequence: "F11"; onActivated: win.toggleFullscreen() }
}
