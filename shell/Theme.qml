pragma Singleton
import QtQuick
import MyShell

// Global look settings. `scale` sizes the shell chrome; `textScale` sizes text on top of that;
// `brightness` dims the whole screen (software, there is no backlight in a VM).
QtObject {
    id: theme
    property real scale: Number(Settings.value("display/scale", 1.0))
    property real textScale: Number(Settings.value("display/textScale", 1.0))
    property real brightness: Number(Settings.value("display/brightness", 1.0))
    property int terminalFontPt: Number(Settings.value("display/terminalFontPt", 11))
    // keyboard layout sent to Wayland clients (xkb): us / no / is, Apple-keyboard variant
    property string keyboardLayout: String(Settings.value("input/layout", "us"))
    readonly property var layouts: [ { id: "us", label: "English", badge: "EN" }, { id: "no", label: "Norsk", badge: "NO" }, { id: "is", label: "Íslenska", badge: "IS" } ]
    function setKeyboardLayout(l) { keyboardLayout = l; Settings.set("input/layout", l) }
    // ---- colour theme (Omarchy-compatible palettes in /usr/share/mylinux/themes) ----
    property string themeId: String(Settings.value("theme/id", "mylinux"))
    property int backgroundIndex: Number(Settings.value("theme/background", 0))
    readonly property var themeData: (ThemeStore.themes, ThemeStore.theme(themeId))
    readonly property var colors: themeData && themeData.colors ? themeData.colors : {}
    readonly property bool isLight: !!(themeData && themeData.light)
    readonly property color bg: colors.background || "#1a1b26"
    readonly property color fg: colors.foreground || "#c0caf5"
    readonly property color accent: colors.accent || colors.color4 || "#7aa2f7"
    readonly property string background: {
        const b = themeData && themeData.backgrounds ? themeData.backgrounds : []
        return b.length ? "file://" + b[backgroundIndex % b.length] : "qrc:/qt/qml/MyShell/assets/wallpaper.png"
    }
    // panel colours derived from the theme
    readonly property color panelTint: isLight ? Qt.rgba(1, 1, 1, 0.55) : Qt.rgba(bg.r, bg.g, bg.b, 0.72)
    readonly property color barTint: isLight ? Qt.rgba(1, 1, 1, 0.45) : Qt.rgba(bg.r, bg.g, bg.b, 0.35)
    readonly property color text: isLight ? "#1c1c1e" : "#f2f2f5"
    readonly property color textDim: isLight ? "#5a5a60" : "#9a9aa2"
    function setTheme(id) {
        themeId = id; backgroundIndex = 0
        Settings.set("theme/id", id); Settings.set("theme/background", 0)
        ThemeStore.applyTerminal(id, terminalFontPt)
    }
    function nextBackground() {
        const b = themeData && themeData.backgrounds ? themeData.backgrounds : []
        if (b.length < 2) return
        backgroundIndex = (backgroundIndex + 1) % b.length; Settings.set("theme/background", backgroundIndex)
    }
    readonly property string uiFont: "Inter"          // fontconfig falls back to DejaVu Sans if absent
    readonly property string monoFont: "DejaVu Sans Mono"

    function px(v) { return Math.round(v * scale) }                 // chrome sizes
    function fpx(v) { return Math.round(v * scale * textScale) }    // font sizes
    // Wayland output scale stays 1: clients are scaled as surfaces by the compositor (blurry above
    // 1x but always geometrically right). Crisp HiDPI needs the fractional-scale protocol; later.
    readonly property int outputScale: 1

    // write the terminal palette for the persisted theme at start-up (foot reads it per launch)
    Component.onCompleted: ThemeStore.applyTerminal(themeId, terminalFontPt)
    function setScale(v) { scale = v; Settings.set("display/scale", v) }
    // Our macOS-style title bars: "auto" = only for apps that do not decorate themselves, "always", "never"
    property string titleBars: String(Settings.value("wm/titlebars", "auto"))
    function setTitleBars(v) { titleBars = v; Settings.set("wm/titlebars", v) }
    function setTextScale(v) { textScale = v; Settings.set("display/textScale", v) }
    function setBrightness(v) { brightness = v; Settings.set("display/brightness", v) }
    function setTerminalFontPt(v) { terminalFontPt = v; Settings.set("display/terminalFontPt", v); ThemeStore.applyTerminal(themeId, v) }
}
