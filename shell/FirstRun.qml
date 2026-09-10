import QtQuick
import MyShell

// First-boot dialog, driven by what S45apps found (/run/apps-disk.state) and what apps-setup reports
// (/run/apps-setup.status): a blank disk is offered for setup, an interrupted setup for continuation, a failed
// stage for retry; disks that are not ours are reported and never formatted. Hidden while the setup window runs.
Item {
    id: fr
    property Item backdrop
    property var desktop
    property string diskState: "unknown"      // mounted | setup | blank | none | ambiguous | foreign | unreadable | mount-failed
    property string diskInfo: ""
    property string setupState: ""            // running | failed | partial | done | ""
    property string setupStage: ""
    property string setupMessage: ""
    readonly property bool ready: Launcher.fileExists("/mnt/apps/.mylinux/ready")
    readonly property bool needed: !ready && diskState !== "unknown"
    readonly property bool canSetup: diskState === "blank" || diskState === "setup" || (diskState === "mounted" && !ready)
    property bool dismissed: false
    anchors.fill: parent
    visible: needed && !dismissed && setupState !== "running"
    z: 25
    function readStatus() {
        const ds = Launcher.readFile("/run/apps-disk.state").trim()
        diskState = ds.length ? ds : (Launcher.fileExists("/run/apps-disk.state") ? "none" : "unknown")
        diskInfo = Launcher.readFile("/run/apps-disk.info").trim()
        const st = Launcher.readFile("/run/apps-setup.status")
        const field = (k) => { const m = st.match(new RegExp("^" + k + "=(.*)$", "m")); return m ? m[1].trim() : "" }
        setupState = field("state"); setupStage = field("stage"); setupMessage = field("message")
    }
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: { const was = fr.ready; fr.readStatus(); if (!was && fr.ready && fr.desktop) fr.desktop.compositor.runAutostart() } }
    readonly property string headline: setupState === "failed" ? "Setting up the apps disk stopped"
        : diskState === "blank" ? "Welcome to mylinux"
        : diskState === "setup" || diskState === "mounted" ? "The apps disk is not finished"
        : diskState === "none" ? "No apps disk"
        : "The apps disk cannot be used"
    readonly property string body: setupState === "failed" ? "Stage “" + setupStage + "”: " + setupMessage + " Nothing on the disk was lost; Retry continues from that stage."
        : diskState === "blank" ? "The apps disk is empty. Setting it up downloads a minimal Debian, Chromium, Claude Code and Codex (about 1 GB, a few minutes) into out/apps.img. Your home directory, logins and installed software persist there across reboots."
        : diskState === "setup" || diskState === "mounted" ? "An earlier setup did not complete. Continuing picks up at the first unfinished stage; what is already installed stays."
        : diskState === "none" ? "Start myLinux with run.sh, which attaches out/apps.img as the apps disk. Without it apps run from RAM only and nothing persists."
        : diskInfo + " It was left untouched: myLinux only formats a disk that reads back completely blank. To start over on purpose, remove out/apps.img on the Mac."
    readonly property string buttonText: setupState === "failed" ? "Retry" : diskState === "blank" ? "Set up the apps disk" : "Continue setup"

    Rectangle { anchors.fill: parent; color: "#33000000" }
    Item {
        width: Theme.px(560); height: box.height + Theme.px(48)
        anchors.centerIn: parent
        GlassPanel { anchors.fill: parent; backdrop: fr.backdrop; radius: Theme.px(18); tint: "#c81c1c22"; borderColor: "#55ffffff"; saturation: 0.15; dim: 0.25 }
        Column {
            id: box
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(24) }
            spacing: Theme.px(14)
            Row { spacing: Theme.px(14)
                AppIcon { kind: "clock"; size: Theme.px(48); anchors.verticalCenter: parent.verticalCenter }
                Column { spacing: 2; anchors.verticalCenter: parent.verticalCenter
                    Text { text: fr.headline; color: "#f2f2f5"; font.pixelSize: Theme.fpx(20); font.family: Theme.uiFont; font.bold: true }
                    Text { text: "The OS runs from RAM. Apps and your files live on the apps disk."; color: "#c9c9ce"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont } } }
            Text { width: parent.width; wrapMode: Text.WordWrap; color: "#e6e6ea"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont; text: fr.body }
            Text { visible: fr.setupState === "partial"; width: parent.width; wrapMode: Text.WordWrap; color: "#f0c674"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; text: fr.setupMessage }
            Row { spacing: Theme.px(10)
                Rectangle { visible: fr.canSetup; width: Theme.px(200); height: Theme.px(40); radius: Theme.px(8); color: sb.pressed ? "#2f5fd0" : "#3d6de6"
                    Text { anchors.centerIn: parent; text: fr.buttonText; color: "white"; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont; font.bold: true }
                    MouseArea { id: sb; anchors.fill: parent; onClicked: { fr.setupState = "running"; Launcher.launch("/usr/bin/apps-setup-window") } } }
                Rectangle { width: Theme.px(120); height: Theme.px(40); radius: Theme.px(8); color: "#2a2a30"; border.color: "#3a3a42"
                    Text { anchors.centerIn: parent; text: fr.canSetup ? "Later" : "Close"; color: "#e6e6ea"; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont }
                    MouseArea { anchors.fill: parent; onClicked: fr.dismissed = true } } }
            Text { text: fr.canSetup ? "Later: run  apps-setup  in a terminal, or use the Setup › Install menu." : "Details: /run/apps-disk.info in a terminal (⌘ Enter)."; color: "#8f8f96"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont }
        }
    }
}
