import QtQuick
import MyShell

// ⌘Space: the Omarchy-style menu (Apps, Learn, Trigger, Style, Setup, Install, Remove, Update, About,
// System) with a search field on top: type to find anything in it. Arrow keys + Enter, Esc goes back / closes.
// Prefixes: "= 2*21" calculator, "? query" web search, "install <pkg>" / "remove <pkg>" apt on the apps disk.
Item {
    id: spot
    property var desktop
    property Item backdrop
    property bool open: false
    property string mode: "search"      // "search" | "menu"
    property var stack: []              // menu breadcrumb (list of category ids)
    property int selected: 0
    anchors.fill: parent
    visible: open
    z: 30

    function show(m) {
        if (m === "theme") ThemeStore.rescan()
        mode = m; stack = []; input.text = ""; selected = 0; open = true
        if (desktop && desktop.compositor && desktop.compositor.defaultSeat)
            desktop.compositor.defaultSeat.keyboardFocus = null     // keys come to us, not the app
        input.forceActiveFocus()
        refresh()
    }
    function showCategory(id) { show("menu"); stack = [id]; selected = 0; refresh() }
    function hide() {
        open = false; input.text = ""
        if (desktop && desktop.focusedWindow) desktop.focusedWindow.raise()   // gives the key focus back
    }

    // ---- catalogue ------------------------------------------------------------------------------
    function apps() {
        const a = desktop ? desktop.dockApps() : []
        return a.map(x => ({ label: x.name, hint: "Application", kind: x.kind, run: () => desktop.launch(x.exec), keys: x.appId }))
    }
    property var categories: [
        { id: "apps",    label: "Apps",    glyph: "▦", hint: "Launch an application" },
        { id: "learn",   label: "Learn",   glyph: "◉", hint: "Keybindings, manuals" },
        { id: "trigger", label: "Trigger", glyph: "➶", hint: "Toggle tiling, backgrounds, Mac window" },
        { id: "style",   label: "Style",   glyph: "✎", hint: "Theme, backgrounds, scale, title bars" },
        { id: "setup",   label: "Setup",   glyph: "⚙", hint: "Display, keyboard, apps disk, agents" },
        { id: "install", label: "Install", glyph: "⤓", hint: "Install software with apt" },
        { id: "remove",  label: "Remove",  glyph: "⊟", hint: "Remove software" },
        { id: "update",  label: "Update",  glyph: "⟳", hint: "Update the apps disk" },
        { id: "about",   label: "About",   glyph: "i", hint: "About this system" },
        { id: "system",  label: "System",  glyph: "⏻", hint: "Restart or shut down" }
    ]
    function inTerminal(title, cmd) { desktop.launchArgs("/usr/bin/foot", ["-T", title, "sh", "-c", cmd + "; echo; echo 'Press Enter to close.'; read x"]) }
    function categoryItems(id) {
        switch (id) {
        case "apps": return apps()
        case "learn": return [
            { label: "Keybindings", hint: "⌘K", glyph: "⌘", run: () => desktop.showKeys() },
            { label: "myLinux on GitHub", hint: "README, releases, source", glyph: "◉", run: () => desktop.launchArgs("/usr/bin/firefox", ["https://github.com/adminmylinux/mylinux"]) },
            { label: "Omarchy manual", hint: "the workflow myLinux follows", glyph: "◉", run: () => desktop.launchArgs("/usr/bin/firefox", ["https://learn.omarchy.org"]) } ]
        case "trigger": return [
            { label: "Next background", hint: "⌘⌃Space", glyph: "▨", run: () => Theme.nextBackground() },
            { label: "Tiling on/off", hint: "⌘⇧T", glyph: "▥", run: () => desktop.toggleTiling() },
            { label: "Float / tile this window", hint: "⌘T", glyph: "▢", run: () => { if (desktop.focusedWindow) desktop.setFloating(desktop.focusedWindow, desktop.focusedWindow.tiled) } },
            { label: "Cycle windows", hint: "⌥Tab", glyph: "⇄", run: () => desktop.cycleWindows() },
            { label: "Screenshot", hint: "Print · saved in your home", glyph: "▣", run: () => desktop.screenshot() },
            { label: "Fill Mac screen", hint: "Mac window", glyph: "⤢", run: () => Launcher.hostCommand("fit") },
            { label: "Mac full screen", hint: "Mac window", glyph: "⤢", run: () => Launcher.hostCommand("fullscreen") } ]
        case "style": return [
            { label: "Theme…", hint: "⌘⌃⇧Space", glyph: "◐", run: () => { mode = "theme"; stack = []; input.text = ""; refresh(); open = true } },
            { label: "Download Omarchy backgrounds", hint: "real photos for every theme", glyph: "⤓", run: () => inTerminal("Downloading backgrounds", "theme-fetch-backgrounds") },
            { label: "Next background", hint: "⌘⌃Space", glyph: "▨", run: () => Theme.nextBackground() },
            { label: "Scale 1x", hint: "Display", glyph: "1x", run: () => Theme.setScale(1) },
            { label: "Scale 1.5x", hint: "Display", glyph: "1.5", run: () => Theme.setScale(1.5) },
            { label: "Scale 2x", hint: "Display", glyph: "2x", run: () => Theme.setScale(2) },
            { label: "Title bars: auto", hint: "only for apps without their own (now: " + Theme.titleBars + ")", glyph: "▭", run: () => Theme.setTitleBars("auto") },
            { label: "Title bars: always", hint: "macOS-style bar on every window", glyph: "▭", run: () => Theme.setTitleBars("always") },
            { label: "Title bars: never", hint: "bare windows, Omarchy-style", glyph: "▭", run: () => Theme.setTitleBars("never") },
            { label: "Panels: solid", hint: "opaque menus and sheets" + (Theme.solidPanels ? "  ✓" : ""), glyph: "▰", run: () => Theme.setSolidPanels(true) },
            { label: "Panels: glass", hint: "see-through, blurred" + (Theme.solidPanels ? "" : "  ✓"), glyph: "▱", run: () => Theme.setSolidPanels(false) },
            { label: "Dock: auto-hide", hint: "appears when the pointer touches the bottom edge" + (Theme.dockAutoHide ? "  ✓" : ""), glyph: "▁", run: () => Theme.setDockAutoHide(true) },
            { label: "Dock: always visible", hint: "windows stop above it" + (Theme.dockAutoHide ? "" : "  ✓"), glyph: "▂", run: () => Theme.setDockAutoHide(false) } ]
        case "setup": return [
            { label: "Display settings", hint: "Brightness · Text size · Scale", glyph: "🖥", run: () => desktop.openDisplayPanel() } ]
            .concat(Theme.layouts.map(l => ({ label: "Keyboard: " + l.label, hint: l.badge + (l.id === Theme.keyboardLayout ? "  ✓" : ""), glyph: "⌨", run: () => Theme.setKeyboardLayout(l.id) })))
            .concat([
            { label: "Set up / repair the apps disk", hint: "apps-setup", glyph: "⤓", run: () => desktop.launch("/usr/bin/apps-setup-window") },
            { label: "Install / update Claude Code and Codex", hint: "apps-setup-ai", glyph: "✳", run: () => inTerminal("Installing agents", "apps-setup-ai") } ])
        case "install": return [
            { label: "Install a package…", hint: "type: install <name>", glyph: "⤓", run: () => { input.text = "install " } },
            { label: "Firefox", hint: "firefox-esr", glyph: "⤓", run: () => desktop.launch("/usr/bin/firefox") },
            { label: "Remote Desktop", hint: "Remmina: VNC, RDP, SSH in tabs", glyph: "⤓", run: () => desktop.launch("/usr/bin/remmina") },
            { label: "Claude Code", hint: "claude", glyph: "⤓", run: () => desktop.launch("/usr/bin/claude-code") },
            { label: "LibreOffice", hint: "apt: libreoffice", glyph: "⤓", run: () => installPkg("libreoffice") },
            { label: "VS Code (Codium)", hint: "apt: codium", glyph: "⤓", run: () => installPkg("codium") },
            { label: "GIMP", hint: "apt: gimp", glyph: "⤓", run: () => installPkg("gimp") } ]
        case "remove": return [
            { label: "Remove a package…", hint: "type: remove <name>", glyph: "⊟", run: () => { input.text = "remove " } },
            { label: "Clean apt caches", hint: "apt-get clean · autoremove", glyph: "⊟", run: () => inTerminal("Cleaning", "apps-run apt-get autoremove -y; apps-run apt-get clean") } ]
        case "update": return [ { label: "Update apps disk", hint: "apt update && apt upgrade", glyph: "⟳", run: () => desktop.launch("/usr/bin/apps-update") } ]
        case "about": return [ { label: "About myLinux", hint: "", glyph: "i", run: () => desktop.showAbout() } ]
        case "system": return [
            { label: "Restart the desktop", hint: "restarts the shell, closes apps", glyph: "↻", run: () => desktop.launchArgs("/etc/init.d/S99shell", ["restart"]) },
            { label: "Restart", hint: "System", glyph: "↻", run: () => desktop.systemRestart() },
            { label: "Shut Down", hint: "System", glyph: "⏻", run: () => desktop.systemShutdown() } ]
        }
        return []
    }
    // everything the menu can do, flat, for typed search
    function everything() {
        let all = categories.map(c => ({ label: c.label, hint: c.hint, glyph: c.glyph, category: c.id }))
        for (const c of categories) all = all.concat(categoryItems(c.id).map(e => Object.assign({}, e, { hint: c.label + (e.hint ? " · " + e.hint : "") })))
        return all
    }
    function installPkg(p) { desktop.launchArgs("/usr/bin/apps-install", [p, p, "/usr/bin/" + p, "/usr/bin/true"]) }

    // ---- filtering ----------------------------------------------------------------------------
    property var results: []
    function refresh() {
        const q = input.text.trim()
        let list = []
        if (mode === "theme" && q.startsWith("install ")) {
            const u = q.slice(8).trim()
            list = u.length ? [{ label: "Install theme from " + u, hint: "GitHub owner/repo, GitHub URL or git URL (Omarchy format)", glyph: "⤓",
                                 run: () => desktop.launchArgs("/usr/bin/foot", ["-T", "Installing theme", "sh", "-c", "theme-install '" + u.replace(/'/g, "") + "'; echo; echo 'Press Enter to close.'; read x"]) }] : []
        } else if (mode === "theme") {
            const ql = q.toLowerCase()
            list = ThemeStore.themes.filter(t => q === "" || t.name.toLowerCase().indexOf(ql) >= 0)
                .map(t => ({ label: t.name + (t.id === Theme.themeId ? "  ✓" : ""), hint: (t.light ? "Light" : "Dark") + " · " + t.backgrounds.length + " background" + (t.backgrounds.length === 1 ? "" : "s"), swatch: [t.colors.background, t.colors.color1, t.colors.color2, t.colors.color3, t.colors.color4, t.colors.color5, t.colors.accent], run: () => Theme.setTheme(t.id) }))
            // extras stay reachable while typing ("down", "omarchy", "install" ... match their labels)
            list = list.concat([
                { label: "Download Omarchy backgrounds for all themes", hint: "≈ one repository download; adds the real photos to every theme", glyph: "⤓",
                  run: () => desktop.launchArgs("/usr/bin/foot", ["-T", "Downloading backgrounds", "sh", "-c", "theme-fetch-backgrounds; echo; echo 'Press Enter to close.'; read x"]) },
                { label: "Install a theme from GitHub…", hint: "type: install owner/repo", glyph: "⤓", run: () => { mode = "theme"; input.text = "install "; open = true } }
            ].filter(e => q === "" || (e.label + " " + e.hint).toLowerCase().indexOf(ql) >= 0))
        } else if (mode === "menu" && stack.length === 0 && q === "") {
            list = categories.map(c => ({ label: c.label, hint: c.hint, glyph: c.glyph, category: c.id }))
        } else if (mode === "menu" && stack.length > 0 && q === "") {
            list = categoryItems(stack[stack.length - 1])
        } else if (q.startsWith("=")) {
            let v = "…"
            try { const e = q.slice(1).replace(/[^0-9+\-*/().% ]/g, ""); v = e.length ? String(Function('"use strict";return (' + e + ')')()) : "" } catch (err) { v = "…" }
            list = [{ label: v, hint: "Calculator", glyph: "=", run: () => {} }]
        } else if (q.startsWith("?")) {
            const s = q.slice(1).trim()
            list = [{ label: "Search the web for “" + s + "”", hint: "Firefox", glyph: "?", run: () => desktop.launchArgs("/usr/bin/firefox", ["https://duckduckgo.com/?q=" + encodeURIComponent(s)]) }]
        } else if (q.startsWith("install ")) {
            const p = q.slice(8).trim()
            list = p.length ? [{ label: "Install " + p, hint: "apt install " + p + " (apps disk)", glyph: "⤓", run: () => installPkg(p) }] : []
        } else if (q.startsWith("remove ")) {
            const p = q.slice(7).trim().replace(/[^A-Za-z0-9.+-]/g, "")
            list = p.length ? [{ label: "Remove " + p, hint: "apt remove " + p + " (apps disk)", glyph: "⊟", run: () => inTerminal("Removing " + p, "apps-run apt-get remove -y " + p) }] : []
        } else {
            // typed text searches everything the menu offers: categories, their entries, apps, actions
            const all = q === "" ? apps() : everything()
            const ql = q.toLowerCase()
            list = q === "" ? all : all.filter(e => (e.label + " " + (e.keys || "") + " " + (e.hint || "")).toLowerCase().indexOf(ql) >= 0)
                .sort((a, b) => { const la = a.label.toLowerCase().indexOf(ql), lb = b.label.toLowerCase().indexOf(ql); return (la < 0 ? 99 : la) - (lb < 0 ? 99 : lb) })
        }
        results = list
        if (selected >= list.length) selected = Math.max(0, list.length - 1)
    }
    function activate(i) {
        const e = results[i]; if (!e) return
        if (e.category) { stack = stack.concat([e.category]); selected = 0; refresh(); return }
        hide()
        if (e.run) e.run()
    }
    function back() {
        if (mode === "menu" && stack.length > 0) { stack = stack.slice(0, -1); selected = 0; refresh() } else hide()
    }

    // ---- ui -------------------------------------------------------------------------------------
    MouseArea { anchors.fill: parent; onPressed: spot.hide() }          // click-away
    Rectangle { anchors.fill: parent; color: "#22000000" }              // slight dim

    Item {
        id: dialog
        width: Theme.px(620); height: header.height + list.height + Theme.px(24)
        anchors.horizontalCenter: parent.horizontalCenter; y: Theme.px(150)
        MouseArea { anchors.fill: parent }                              // swallow clicks inside
        GlassPanel { anchors.fill: parent; backdrop: spot.backdrop; radius: Theme.px(18); tint: "#ee1c1c22"; borderColor: "#55ffffff"; saturation: 0.15; dim: 0.25 }

        Column {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(16) }
            spacing: Theme.px(8)
            Row { spacing: Theme.px(8)
                Text { visible: spot.mode === "theme"; text: "Theme"; color: "#8f8f96"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; font.letterSpacing: 1 }
                Text { visible: spot.mode === "menu"; text: "myLinux"; color: "#8f8f96"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; font.letterSpacing: 1 }
                Repeater { model: spot.stack; Text { text: "› " + spot.categories.find(c => c.id === modelData).label; color: "#c9c9ce"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont } }
            }
            Rectangle {
                width: parent.width; height: Theme.px(44); radius: Theme.px(10); color: "#33ffffff"; border.color: "#33ffffff"
                Text { anchors.left: parent.left; anchors.leftMargin: Theme.px(14); anchors.verticalCenter: parent.verticalCenter; text: "⌕"; color: "#c9c9ce"; font.pixelSize: Theme.fpx(18) }
                TextInput {
                    id: input
                    anchors { left: parent.left; right: parent.right; leftMargin: Theme.px(42); rightMargin: Theme.px(14); verticalCenter: parent.verticalCenter }
                    color: "white"; font.pixelSize: Theme.fpx(17); font.family: Theme.uiFont; selectByMouse: true
                    onTextChanged: { spot.selected = 0; spot.refresh() }
                    Keys.onPressed: (ev) => {
                        if (ev.key === Qt.Key_Escape) { spot.back(); ev.accepted = true }
                        else if (ev.key === Qt.Key_Down) { spot.selected = Math.min(spot.selected + 1, spot.results.length - 1); ev.accepted = true }
                        else if (ev.key === Qt.Key_Up) { spot.selected = Math.max(spot.selected - 1, 0); ev.accepted = true }
                        else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) { spot.activate(spot.selected); ev.accepted = true }
                        else if (ev.key === Qt.Key_Tab) { spot.selected = (spot.selected + 1) % Math.max(1, spot.results.length); ev.accepted = true }
                    }
                    Text { anchors.fill: parent; visible: !input.text.length; text: spot.mode === "theme" ? "Pick a theme…" : (spot.mode === "menu" && spot.stack.length === 0 ? "Go…" : "Search…"); color: "#8f8f96"; font: input.font; verticalAlignment: Text.AlignVCenter }
                }
            }
        }

        ListView {
            id: list
            anchors { top: header.bottom; left: parent.left; right: parent.right; margins: Theme.px(12) }
            height: Math.min(contentHeight, Theme.px(46) * 10)   // all ten menu categories without scrolling
            clip: true; interactive: contentHeight > height
            model: spot.results
            currentIndex: spot.selected
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            delegate: Rectangle {
                width: list.width; height: Theme.px(46); radius: Theme.px(8)
                color: index === spot.selected ? Theme.accent : (hov.containsMouse ? "#22ffffff" : "transparent")
                Row {
                    anchors.left: parent.left; anchors.leftMargin: Theme.px(10); anchors.verticalCenter: parent.verticalCenter; spacing: Theme.px(12)
                    Item { width: Theme.px(30); height: Theme.px(30); anchors.verticalCenter: parent.verticalCenter
                        AppIcon { visible: !!modelData.kind; kind: modelData.kind || "terminal"; size: Theme.px(28); anchors.centerIn: parent }
                        Text { visible: !modelData.kind && !modelData.swatch; anchors.centerIn: parent; text: modelData.glyph || "•"; color: "white"; font.pixelSize: Theme.fpx(15); font.family: Theme.uiFont }
                        Rectangle { visible: !!modelData.swatch; anchors.centerIn: parent; width: Theme.px(28); height: Theme.px(28); radius: Theme.px(7); color: modelData.swatch ? modelData.swatch[0] : "black"; border.color: "#44ffffff" } }
                    Column { anchors.verticalCenter: parent.verticalCenter; spacing: 1
                        Text { text: modelData.label; color: "white"; font.pixelSize: Theme.fpx(15); font.family: Theme.uiFont; font.weight: Font.Medium }
                        Text { visible: !!modelData.hint; text: modelData.hint || ""; color: index === spot.selected ? "#dfe6ff" : "#9a9aa2"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont } }
                }
                Text { visible: !!modelData.category; anchors.right: parent.right; anchors.rightMargin: Theme.px(14); anchors.verticalCenter: parent.verticalCenter; text: "›"; color: "#c9c9ce"; font.pixelSize: Theme.fpx(18) }
                Row { visible: !!modelData.swatch; anchors.right: parent.right; anchors.rightMargin: Theme.px(14); anchors.verticalCenter: parent.verticalCenter; spacing: Theme.px(4)
                    Repeater { model: modelData.swatch ? modelData.swatch.slice(1) : []
                        Rectangle { width: Theme.px(14); height: Theme.px(14); radius: Theme.px(4); color: modelData || "gray"; border.color: "#33000000" } } }
                MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true; onClicked: spot.activate(index) }
            }
            Text { visible: spot.results.length === 0; anchors.centerIn: parent; text: "No Results"; color: "#8f8f96"; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont }
        }
    }
}
