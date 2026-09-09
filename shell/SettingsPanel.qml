import QtQuick
import MyShell

// Settings popover (menu bar gear): API keys and tokens. Saved in the home directory and exported
// to every terminal and app as environment variables (OPENROUTER_API_KEY, ...).
Item {
    id: panel
    property Item backdrop
    property var desktop
    width: Theme.px(460); height: col.height + Theme.px(36)
    readonly property var fields: [
        { key: "OPENROUTER_API_KEY", label: "OpenRouter API key", hint: "openrouter.ai/keys" },
        { key: "ANTHROPIC_API_KEY",  label: "Anthropic API key",  hint: "console.anthropic.com" },
        { key: "OPENAI_API_KEY",     label: "OpenAI API key",     hint: "platform.openai.com" },
        { key: "TAILSCALE_API_KEY",  label: "Tailscale API key",  hint: "login.tailscale.com/admin/settings/keys" },
        { key: "GITHUB_TOKEN",       label: "GitHub token",       hint: "github.com/settings/tokens" }
    ]
    property bool reveal: false
    onVisibleChanged: {
        if (visible) { if (desktop && desktop.compositor) desktop.compositor.defaultSeat.keyboardFocus = null; reveal = false; firstField.forceActiveFocus() }
        else if (desktop && desktop.focusedWindow) desktop.focusedWindow.raise()
    }
    property Item firstField

    GlassPanel { anchors.fill: parent; backdrop: panel.backdrop; radius: Theme.px(14); tint: "#cc1b1b22"; borderColor: "#55ffffff"; saturation: 0.1; dim: 0.25 }
    component Label: Text { color: "#9a9aa2"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont; font.bold: true; font.letterSpacing: 1 }

    Column {
        id: col
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(18) }
        spacing: Theme.px(10)
        Row { width: parent.width
            Text { text: "Settings"; color: "#f2f2f5"; font.pixelSize: Theme.fpx(17); font.family: Theme.uiFont; font.bold: true; width: parent.width - showBtn.width }
            Rectangle { id: showBtn; width: showT.width + Theme.px(16); height: Theme.px(24); radius: Theme.px(6); color: "#3a3a44"
                Text { id: showT; anchors.centerIn: parent; text: panel.reveal ? "Hide" : "Show"; color: "white"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont }
                MouseArea { anchors.fill: parent; onClicked: panel.reveal = !panel.reveal } } }
        Label { text: "API KEYS · EXPORTED AS ENVIRONMENT VARIABLES" }
        Repeater {
            model: panel.fields
            Column { width: col.width; spacing: 3
                Row { spacing: Theme.px(8)
                    Text { text: modelData.label; color: "#e6e6ea"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; font.weight: Font.Medium }
                    Text { text: modelData.key; color: "#6e6e78"; font.pixelSize: Theme.fpx(11); font.family: Theme.monoFont }
                    Text { text: Secrets.has(modelData.key) ? "✓ set" : ""; color: "#34c759"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont } }
                Rectangle { width: parent.width; height: Theme.px(30); radius: Theme.px(8); color: "#33ffffff"; border.color: fld.activeFocus ? Theme.accent : "#33ffffff"
                    TextInput { id: fld; anchors { left: parent.left; right: parent.right; margins: Theme.px(10); verticalCenter: parent.verticalCenter }
                        color: "white"; font.pixelSize: Theme.fpx(13); font.family: Theme.monoFont; selectByMouse: true
                        echoMode: panel.reveal ? TextInput.Normal : TextInput.Password
                        text: Secrets.get(modelData.key)
                        onEditingFinished: Secrets.set(modelData.key, text.trim())
                        Keys.onPressed: (ev) => { if (ev.key === Qt.Key_Escape) { panel.visible = false; ev.accepted = true } else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) { Secrets.set(modelData.key, text.trim()); ev.accepted = true } }
                        Component.onCompleted: if (index === 0) panel.firstField = fld
                        Text { anchors.fill: parent; visible: !fld.text.length && !fld.activeFocus; text: modelData.hint; color: "#6e6e78"; font: fld.font; verticalAlignment: Text.AlignVCenter } } } }
        }
        Label { text: "SAVED IN ~/.config/mylinux/secrets.env · NEW TERMINALS AND APPS SEE CHANGES"; color: "#6e6e78"; width: parent.width; elide: Text.ElideRight }
    }
}
