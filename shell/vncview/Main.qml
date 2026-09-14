import QtQuick
import QtQuick.Window
import VncView

// vncview: tabs of VNC connections and SSH terminals, plus a "Machines" tab (saved profiles and a connect form).
// F11 toggles fullscreen (the compositor then grabs every key for the remote; Ctrl+Alt+G releases).
Window {
    id: win
    width: 1280; height: 800
    visible: true
    title: tabs.currentIndex >= 0 && tabs.currentIndex < sessions.length ? sessions[tabs.currentIndex].title + " - vncview" : "vncview"
    color: "#141416"
    readonly property color accent: "#2f6fe6"
    readonly property string font: "Inter"
    property var sessions: []            // { type: "vnc" | "ssh", title, host, port, session }
    property var currentSurface: null    // the VncSurface or TermSurface of the shown tab (the bar's controls act on it)
    readonly property var current: tabs.currentIndex >= 0 && tabs.currentIndex < sessions.length ? sessions[tabs.currentIndex] : null
    property bool fullscreen: visibility === Window.FullScreen

    Component { id: sessionComp; VncSession {} }
    Component { id: sshComp; SshSession {} }
    property bool sessionsTouched: false   // sessionsChanged also fires while the window is built: nothing to save then
    function addTab(entry) { sessionsTouched = true; sessions = sessions.concat([entry]); tabs.currentIndex = sessions.length - 1 }
    function connectTo(name, host, port, username, password, quality) {
        const s = sessionComp.createObject(win)
        s.quality = quality || "balanced"
        addTab({ type: "vnc", title: name && name.length ? name : host, host: host, port: port, username: username || "", session: s })
        s.open(host, port, username || "", password || "")
    }
    function connectSsh(name, host, port, username, password, keyFile, tmux) {
        const s = sshComp.createObject(win)
        addTab({ type: "ssh", title: name && name.length ? name : host, host: host, port: port, username: username || "", keyFile: keyFile || "", tmux: tmux || "", session: s })
        s.open(host, port, username || "", password || "", keyFile || "", tmux || "")
    }
    function openMachine(m) {
        if (m.type === "ssh") connectSsh(m.name, m.host, m.port, m.username, Machines.password(m.name), m.keyFile || "", m.tmux || "")
        else connectTo(m.name, m.host, m.port, m.username, Machines.password(m.name), m.quality)
    }
    // the open tabs, remembered across a shell or machine restart (the shell starts `vnc --restore` when the file exists)
    onSessionsChanged: if (sessionsTouched) Machines.saveSession(sessions.map(e => ({ type: e.type, name: e.title, host: e.host, port: e.port,
                                                                 username: e.username || "", keyFile: e.keyFile || "", tmux: e.tmux || "",
                                                                 quality: e.session.quality || "" })))
    onClosing: Machines.saveSession([])                         // closed on purpose: nothing to bring back
    function restoreSession() {
        for (const t of Machines.session()) {
            const m = Machines.get(t.name)                        // a saved machine: its password and current settings
            if (m.name === t.name) { openMachine(m); continue }
            if (t.type === "ssh") connectSsh(t.name, t.host, t.port, t.username, "", t.keyFile, t.tmux)
            else connectTo(t.name, t.host, t.port, t.username, "", t.quality)
        }
    }
    function closeTab(i) {
        const e = sessions[i]; if (!e) return
        e.session.close(); e.session.destroy()
        sessionsTouched = true
        sessions = sessions.slice(0, i).concat(sessions.slice(i + 1))
        tabs.currentIndex = Math.min(tabs.currentIndex, sessions.length - 1)
    }
    function toggleFullscreen() { visibility = fullscreen ? Window.Windowed : Window.FullScreen }
    Component.onCompleted: if (startRestore) restoreSession(); else if (startHost && startHost.length) {
        const m = Machines.get(startName)
        if (m.type === "ssh") connectSsh(startName, startHost, startPort > 0 && startPort !== 5900 ? startPort : (m.port || 22), m.username || "", startName.length ? Machines.password(startName) : "", m.keyFile || "", m.tmux || "")
        else connectTo(startName, startHost, startPort, m.username || "", startName.length ? Machines.password(startName) : "", m.quality || "balanced")
    }

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
                    Text { id: tt; anchors.centerIn: parent; anchors.horizontalCenterOffset: 4; text: modelData.title + (modelData.type === "ssh" ? " (ssh)" : ""); color: "white"; font.pixelSize: 12; font.family: win.font }
                    Text { anchors.right: parent.right; anchors.rightMargin: 7; anchors.verticalCenter: parent.verticalCenter; text: "×"; color: "#ccc"; font.pixelSize: 14
                           MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: win.closeTab(index) } }
                    MouseArea { anchors.fill: parent; anchors.rightMargin: 20; onClicked: tabs.currentIndex = index } } }
        }
        Row { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; spacing: 10
            Text { visible: win.current !== null
                   text: !win.current ? "" : win.current.type === "ssh"
                         ? (win.current.session.state + "  " + win.current.session.cols + "×" + win.current.session.rows)
                         : (win.current.session.state + (win.current.session.fbWidth ? "  " + win.current.session.fbWidth + "×" + win.current.session.fbHeight : ""))
                   color: "#9a9aa2"; font.pixelSize: 11; font.family: win.font }
            component BarButton: Rectangle { property string label; property bool selected: false; signal clicked()
                width: Math.max(26, bl.implicitWidth + 12); height: 22; radius: 5
                color: selected ? win.accent : bm.containsMouse ? "#3a3a42" : "#2a2a30"; border.color: selected ? win.accent : "#3a3a42"
                Text { id: bl; anchors.centerIn: parent; text: parent.label; color: "white"; font.pixelSize: 12; font.family: win.font }
                MouseArea { id: bm; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked() } }
            // VNC: zoom (fit / steps / real pixels; zoomed in, the view follows the pointer)
            Row { visible: win.current !== null && win.current.type === "vnc" && win.currentSurface !== null; spacing: 4; anchors.verticalCenter: parent.verticalCenter
                BarButton { label: "Fit"; selected: win.currentSurface && win.currentSurface.zoom !== undefined && Math.abs(win.currentSurface.zoom - 1) < 0.001; onClicked: win.currentSurface.zoom = 1 }
                BarButton { label: "−"; onClicked: win.currentSurface.zoomStep(-1) }
                Text { width: 44; height: 22; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
                       text: win.currentSurface && win.currentSurface.displayScale !== undefined ? Math.round(win.currentSurface.displayScale * 100) + "%" : ""; color: "#e6e6ea"; font.pixelSize: 12; font.family: win.font }
                BarButton { label: "+"; onClicked: win.currentSurface.zoomStep(1) }
                BarButton { label: "1:1"; selected: win.currentSurface && win.currentSurface.displayScale !== undefined && Math.abs(win.currentSurface.displayScale - 1) < 0.01; onClicked: win.currentSurface.zoomToPixels() }
            }
            // SSH: text size and paste
            Row { visible: win.current !== null && win.current.type === "ssh" && win.currentSurface !== null; spacing: 4; anchors.verticalCenter: parent.verticalCenter
                BarButton { label: "A−"; onClicked: win.currentSurface.fontPt = win.currentSurface.fontPt - 1 }
                Text { width: 44; height: 22; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter
                       text: win.currentSurface && win.currentSurface.fontPt !== undefined ? win.currentSurface.fontPt + " pt" : ""; color: "#e6e6ea"; font.pixelSize: 12; font.family: win.font }
                BarButton { label: "A+"; onClicked: win.currentSurface.fontPt = win.currentSurface.fontPt + 1 }
                BarButton { label: "Paste"; onClicked: win.currentSurface.paste() }
            }
            Text { text: win.current && win.current.type === "ssh" ? "F11 full screen · Ctrl+Shift+V paste · Shift+PgUp history" : "F11 full screen · Ctrl+Alt+G release keys"; color: "#6e6e78"; font.pixelSize: 11; font.family: win.font }
        }
    }

    // ---- pages ----
    Item {
        anchors.top: bar.bottom; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
        Repeater { model: win.sessions
            Item { id: page; anchors.fill: parent; visible: tabs.currentIndex === index
                readonly property bool isSsh: modelData.type === "ssh"
                VncSurface { id: surf; anchors.fill: parent; visible: !page.isSsh; session: page.isSsh ? null : modelData.session; focus: visible
                             onVisibleChanged: if (visible) { forceActiveFocus(); win.currentSurface = surf }
                             Component.onCompleted: if (visible) { forceActiveFocus(); win.currentSurface = surf }
                             Component.onDestruction: if (win.currentSurface === surf) win.currentSurface = null
                             Keys.onPressed: (ev) => { if (ev.key === Qt.Key_F11) { win.toggleFullscreen(); ev.accepted = true } } }
                TermSurface { id: term; anchors.fill: parent; visible: page.isSsh; session: page.isSsh ? modelData.session : null; focus: visible
                              onVisibleChanged: if (visible) { forceActiveFocus(); win.currentSurface = term }
                              Component.onCompleted: if (visible) { forceActiveFocus(); win.currentSurface = term }
                              Component.onDestruction: if (win.currentSurface === term) win.currentSurface = null
                              Keys.onPressed: (ev) => { if (ev.key === Qt.Key_F11) { win.toggleFullscreen(); ev.accepted = true } } }
                // unknown or changed TLS certificate (VNC): show the fingerprint, trust pins it (~/.config/mylinux/vnc/certs)
                Rectangle { anchors.centerIn: parent; visible: !page.isSsh && modelData.session.state === "untrusted"; width: Math.min(parent.width - 40, 620); height: trustCol.implicitHeight + 36; radius: 10; color: "#ee1e1e22"
                    border.color: !page.isSsh && modelData.session.certChanged ? "#ff5f57" : "#44ffffff"
                    Column { id: trustCol; anchors.centerIn: parent; width: parent.width - 36; spacing: 10
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: !page.isSsh && modelData.session.certChanged ? "#ff8a84" : "white"; font.pixelSize: 15; font.bold: true; font.family: win.font
                               text: !page.isSsh && modelData.session.certChanged ? "The certificate of " + modelData.host + " has changed" : "First connection to " + modelData.host + ": trust its certificate?" }
                        Text { width: parent.width; wrapMode: Text.WordWrap; color: "#c8c8ce"; font.pixelSize: 12; font.family: win.font
                               text: (!page.isSsh && modelData.session.certChanged ? "It no longer matches the certificate you trusted. That happens when wayvnc's certificate is regenerated, or when something else answers on this address. "
                                                                    : "The server uses a self-signed certificate. ")
                                     + "Compare the fingerprint with the server's, for example:  openssl x509 -noout -fingerprint -sha256 -in ~/.config/wayvnc/tls_cert.pem" }
                        Text { width: parent.width; wrapMode: Text.WrapAnywhere; color: "#e6e6ea"; font.pixelSize: 12; font.family: "monospace"
                               text: page.isSsh ? "" : "Name: " + (modelData.session.certName || "(none)") + "\nSHA-256: " + modelData.session.certFingerprint }
                        Row { spacing: 8
                            Rectangle { width: 150; height: 32; radius: 8; color: !page.isSsh && modelData.session.certChanged ? "#c4433c" : win.accent
                                Text { anchors.centerIn: parent; text: !page.isSsh && modelData.session.certChanged ? "Replace and connect" : "Trust and connect"; color: "white"; font.pixelSize: 13; font.bold: true; font.family: win.font }
                                MouseArea { anchors.fill: parent; onClicked: modelData.session.trustCertificate() } }
                            Rectangle { width: 90; height: 32; radius: 8; color: "#2a2a30"; border.color: "#3a3a42"
                                Text { anchors.centerIn: parent; text: "Close"; color: "#e6e6ea"; font.pixelSize: 13; font.family: win.font }
                                MouseArea { anchors.fill: parent; onClicked: win.closeTab(index) } } } } }
                // status overlay while not connected (SSH keeps its terminal readable while connecting: prompts show there)
                Rectangle { anchors.centerIn: parent
                    visible: modelData.session.state !== "connected" && modelData.session.state !== "untrusted" && !(page.isSsh && modelData.session.state === "connecting")
                    width: Math.min(st.implicitWidth, parent.width - 80) + 40; height: st.implicitHeight + 24; radius: 10; color: "#cc1e1e22"; border.color: "#44ffffff"
                    Text { id: st; anchors.centerIn: parent; color: "#e6e6ea"; font.pixelSize: 14; font.family: win.font; horizontalAlignment: Text.AlignHCenter
                           text: modelData.session.state === "connecting" ? "Connecting to " + modelData.host + ":" + modelData.port + "…"
                               : modelData.session.state === "error" ? "Failed: " + modelData.session.error + "\n(click to retry)"
                               : (modelData.session.error ? "Disconnected: " + modelData.session.error : "Disconnected") + " (click to reconnect)" }
                    MouseArea { anchors.fill: parent; onClicked: {
                        const m = Machines.get(modelData.title)
                        if (page.isSsh) modelData.session.open(modelData.host, modelData.port, m.username || "", Machines.password(modelData.title), m.keyFile || "", m.tmux || "")
                        else modelData.session.open(modelData.host, modelData.port, m.username || "", Machines.password(modelData.title)) } } }
            } }

        // Machines page
        Item { anchors.fill: parent; visible: tabs.currentIndex === -1
            Column { id: form; anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 24; spacing: 10; width: Math.min(parent.width - 48, 560)
                Text { text: "Machines"; color: "white"; font.pixelSize: 20; font.family: win.font; font.bold: true }
                Text { text: "VNC desktops and SSH terminals, each in its own tab. Saved in ~/.config/mylinux/vnc/machines.json; passwords in the secrets store. Also: vncview host[:port] or vncview <name> in a terminal."; color: "#9a9aa2"; font.pixelSize: 12; font.family: win.font; width: parent.width; wrapMode: Text.WordWrap }
                Repeater { model: Machines.list
                    Rectangle { width: parent.width; height: 40; radius: 8; color: rowMa.containsMouse ? "#2a2a30" : "#202024"
                        Rectangle { anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; width: 36; height: 18; radius: 4
                                    color: modelData.type === "ssh" ? "#2f6f3a" : "#3d4f8a"
                                    Text { anchors.centerIn: parent; text: modelData.type === "ssh" ? "SSH" : "VNC"; color: "white"; font.pixelSize: 10; font.bold: true; font.family: win.font } }
                        Text { anchors.left: parent.left; anchors.leftMargin: 58; anchors.verticalCenter: parent.verticalCenter
                               text: modelData.name + "   " + modelData.host + ":" + modelData.port + (modelData.username ? "   " + modelData.username : "") + "   " + (modelData.type === "ssh" ? (modelData.keyFile ? "key " + modelData.keyFile + " " : "") + (modelData.tmux ? "tmux " + modelData.tmux : "") : modelData.quality)
                               color: "#e6e6ea"; font.pixelSize: 13; font.family: win.font }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; onClicked: win.openMachine(modelData) }
                        Text { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; text: "remove"; color: "#9a9aa2"; font.pixelSize: 11; font.family: win.font
                               MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: Machines.remove(modelData.name) } } } }
                Item { width: 1; height: 8 }
                Text { text: "Add or edit"; color: "white"; font.pixelSize: 15; font.family: win.font; font.bold: true }
                Row { spacing: 8
                    Repeater { model: ["vnc", "ssh"]
                        Rectangle { width: 110; height: 28; radius: 6; color: kind.value === modelData ? win.accent : "#2a2a30"
                            Text { anchors.centerIn: parent; text: modelData === "ssh" ? "SSH terminal" : "VNC desktop"; color: "white"; font.pixelSize: 12; font.family: win.font }
                            MouseArea { anchors.fill: parent; onClicked: kind.value = modelData } } }
                    Item { id: kind; property string value: "vnc"; readonly property bool ssh: value === "ssh" } }
                component Field: Rectangle { property alias text: inp.text; property string placeholder; property bool secret: false; property Item next
                    width: 520; height: 32; radius: 8; color: "#2a2a30"; border.color: inp.activeFocus ? win.accent : "#3a3a42"
                    TextInput { id: inp; anchors.fill: parent; anchors.margins: 8; verticalAlignment: TextInput.AlignVCenter; color: "white"; font.pixelSize: 13; font.family: win.font; selectByMouse: true; echoMode: parent.secret ? TextInput.Password : TextInput.Normal
                                Keys.onTabPressed: if (parent.next) parent.next.forceActiveFocus()
                                Text { anchors.fill: parent; visible: !inp.text.length; text: parent.parent.placeholder; color: "#6e6e78"; font: inp.font; verticalAlignment: Text.AlignVCenter } }
                    function forceActiveFocus() { inp.forceActiveFocus() } }
                Field { id: fName; placeholder: "Name (omarchy)"; next: fHost }
                Field { id: fHost; placeholder: "Host or IP"; next: fPort }
                Field { id: fPort; placeholder: kind.ssh ? "Port (22)" : "Port (5900)"; next: fUser }
                Field { id: fUser; placeholder: kind.ssh ? "Username" : "Username (wayvnc with auth; empty for password-only servers)"; next: fPass }
                Field { id: fPass; placeholder: kind.ssh ? "Password (optional: keys in ~/.ssh are tried first)" : "Password"; secret: true; next: fKey }
                Field { id: fKey; visible: kind.ssh; placeholder: "Key file (optional, for example /root/.ssh/id_ed25519)"; next: fTmux }
                Field { id: fTmux; visible: kind.ssh; placeholder: "tmux session (optional, e.g. main): the shell survives a closed tab; needs tmux on the machine" }
                Row { spacing: 8; visible: !kind.ssh
                    Repeater { model: ["fast", "balanced", "best"]
                        Rectangle { width: 90; height: 28; radius: 6; color: quality.value === modelData ? win.accent : "#2a2a30"
                            Text { anchors.centerIn: parent; text: modelData; color: "white"; font.pixelSize: 12; font.family: win.font }
                            MouseArea { anchors.fill: parent; onClicked: quality.value = modelData } } }
                    Item { id: quality; property string value: "balanced" } }
                function formEntry() {
                    const port = parseInt(fPort.text) || (kind.ssh ? 22 : 5900)
                    return { name: fName.text.length ? fName.text : fHost.text, type: kind.value, host: fHost.text, port: port,
                             username: fUser.text, quality: quality.value, keyFile: fKey.text, tmux: fTmux.text }
                }
                Row { spacing: 8
                    Rectangle { width: 140; height: 34; radius: 8; color: "#3d6de6"
                        Text { anchors.centerIn: parent; text: "Save & connect"; color: "white"; font.pixelSize: 13; font.family: win.font; font.bold: true }
                        MouseArea { anchors.fill: parent; onClicked: {
                            if (!fHost.text.length) return
                            const e = form.formEntry()
                            Machines.save(e, fPass.text)
                            win.openMachine(Machines.get(e.name)) } } }
                    Rectangle { width: 120; height: 34; radius: 8; color: "#2a2a30"; border.color: "#3a3a42"
                        Text { anchors.centerIn: parent; text: "Connect once"; color: "#e6e6ea"; font.pixelSize: 13; font.family: win.font }
                        MouseArea { anchors.fill: parent; onClicked: {
                            if (!fHost.text.length) return
                            const e = form.formEntry()
                            if (kind.ssh) win.connectSsh(fName.text, e.host, e.port, e.username, fPass.text, e.keyFile, e.tmux)
                            else win.connectTo(fName.text, e.host, e.port, e.username, fPass.text, e.quality) } } } }
            }
        }
    }
    Shortcut { sequence: "F11"; onActivated: win.toggleFullscreen() }
}
