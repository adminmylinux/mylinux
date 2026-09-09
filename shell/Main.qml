import QtQuick
import QtWayland.Compositor
import QtWayland.Compositor.XdgShell
import MyShell

WaylandCompositor {
    id: compositor
    socketName: Launcher.socketName()

    // One screen = one output = the eglfs window.
    WaylandOutput {
        compositor: compositor
        sizeFollowsWindow: true
        scaleFactor: Theme.outputScale
        window: Desktop {
            id: desktop
            compositor: compositor
        }
    }

    // Standard desktop protocol: windows come in as xdg_toplevels.
    XdgShell {
        onToplevelCreated: (toplevel, xdgSurface) => desktop.addWindow(toplevel, xdgSurface)
    }
    // We draw the title bars, so ask clients not to.
    XdgDecorationManagerV1 { preferredMode: XdgToplevel.ServerSideDecoration }

    function applyKeymap() {
        const km = compositor.defaultSeat.keymap
        km.layout = Theme.keyboardLayout; km.variant = "mac"; km.model = "pc105"
    }
    Connections { target: Theme; function onKeyboardLayoutChanged() { compositor.applyKeymap() } }

    // Autostart list lives in Settings (share/mylinux.ini): [session] autostart=cmd1,cmd2,...
    // Entries that need the apps disk are skipped until it is set up (FirstRun runs this again afterwards).
    property bool autostarted: false
    function runAutostart() {
        if (autostarted) return
        const ready = Launcher.fileExists("/mnt/apps/usr/bin/chromium")
        const needsDisk = ["chromium", "firefox", "chatgpt", "claude-web", "claude-code", "codex", "apps-"]
        const list = String(Settings.value("session/autostart", "/usr/bin/claude-web,/usr/bin/chatgpt")).split(",")
        let launched = 0
        for (let cmd of list) {
            cmd = cmd.trim(); if (!cmd.length) continue
            if (!ready && needsDisk.some(k => cmd.indexOf(k) >= 0)) continue
            Launcher.launch(cmd); launched++
        }
        if (!ready && launched === 0) Launcher.launch("/usr/bin/foot")
        if (ready) autostarted = true
    }
    Component.onCompleted: { applyKeymap(); runAutostart() }
}
