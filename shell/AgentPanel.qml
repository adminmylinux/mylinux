import QtQuick
import MyShell

// Agent usage popover (Claude Code / Codex): limits, tokens by day, tokens by model.
Item {
    id: panel
    property Item backdrop
    property string agent: "claude"          // "claude" | "codex"
    readonly property var usage: agent === "claude" ? AgentUsage.claude : AgentUsage.codex
    width: Theme.px(400); height: col.height + Theme.px(40)

    GlassPanel { anchors.fill: parent; backdrop: panel.backdrop; radius: Theme.px(14); tint: "#cc1b1b22"; borderColor: "#55ffffff"; saturation: 0.1; dim: 0.25 }

    component Label: Text { color: "#9a9aa2"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont; font.bold: true; font.letterSpacing: 1 }
    component Value: Text { color: "#e6e6ea"; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont }
    component Bar: Item {
        property real frac: 0
        width: parent.width; height: Theme.px(6)
        Rectangle { anchors.fill: parent; radius: height / 2; color: "#3a3a44" }
        Rectangle { width: Math.max(height, parent.width * Math.min(1, Math.max(0, frac))); height: parent.height; radius: height / 2; color: "#d9d9e6" }
    }
    function fmt(n) { n = Number(n); return n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e3 ? (n / 1e3).toFixed(1) + "K" : String(n) }
    function resetsIn(iso) {
        if (!iso) return ""
        const ms = new Date(iso).getTime() - Date.now(); if (isNaN(ms) || ms <= 0) return "Resets soon"
        const h = Math.floor(ms / 3.6e6), m = Math.floor((ms % 3.6e6) / 6e4), d = Math.floor(h / 24)
        return "Resets in " + (d > 0 ? d + "d " + (h % 24) + "h" : h + "h " + m + "m")
    }
    function maxTokens(rows) { let m = 1; for (const r of rows || []) m = Math.max(m, Number(r.tokens)); return m }

    Column {
        id: col
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: Theme.px(20) }
        spacing: Theme.px(12)

        Row { spacing: Theme.px(14)
            AppIcon { kind: panel.agent === "claude" ? "claude" : "codex"; size: Theme.px(40); anchors.verticalCenter: parent.verticalCenter }
            Column { spacing: 2; anchors.verticalCenter: parent.verticalCenter
                Text { text: panel.agent === "claude" ? "Claude Code" : "Codex"; color: "#f2f2f5"; font.pixelSize: Theme.fpx(18); font.family: Theme.uiFont; font.bold: true }
                Label { text: panel.usage && panel.usage.plan ? panel.usage.plan : (panel.usage && panel.usage.signedIn ? "SIGNED IN" : "NOT SIGNED IN") } }
        }
        Row { spacing: Theme.px(8)
            Repeater { model: [ { id: "claude", t: "Claude Code" }, { id: "codex", t: "Codex" } ]
                Rectangle { width: (col.width - Theme.px(8)) / 2; height: Theme.px(36); radius: Theme.px(6)
                    color: panel.agent === modelData.id ? "#4d4d58" : "#2a2a30"; border.color: panel.agent === modelData.id ? "#9a9aa8" : "#3a3a42"
                    Text { anchors.centerIn: parent; text: modelData.t; color: "#e6e6ea"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont }
                    MouseArea { anchors.fill: parent; onClicked: panel.agent = modelData.id } } }
        }
        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Label { text: "LIMITS" }
        Text { visible: !(panel.usage && panel.usage.limits && panel.usage.limits.length)
               text: panel.usage && !panel.usage.signedIn ? "Sign in (" + (panel.agent === "claude" ? "claude" : "codex") + " in a terminal) to see limits"
                     : (panel.usage && panel.usage.limitsError ? "Limits unavailable: " + panel.usage.limitsError : (AgentUsage.busy ? "Loading…" : "No limit data yet"))
               color: "#9a9aa2"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; width: col.width; wrapMode: Text.WordWrap }
        Repeater { model: panel.usage && panel.usage.limits ? panel.usage.limits : []
            Column { width: col.width; spacing: Theme.px(4)
                Item { width: parent.width; height: Theme.px(18)
                    Text { text: modelData.label; color: "#e6e6ea"; font.pixelSize: Theme.fpx(14); font.family: Theme.uiFont; anchors.left: parent.left }
                    Value { text: Math.round(modelData.pct * 100) + "%"; anchors.right: parent.right } }
                Bar { frac: modelData.pct }
                Text { text: panel.resetsIn(modelData.resetsAt); color: "#8a8a92"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont } } }
        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Label { text: "TOKENS BY DAY" }
        Repeater { model: panel.usage && panel.usage.days ? panel.usage.days : []
            Item { width: col.width; height: Theme.px(20)
                Text { text: modelData.label; color: modelData.label === "Today" ? "#e6e6ea" : "#9a9aa2"; font.bold: modelData.label === "Today"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; width: Theme.px(60) }
                Bar { anchors.verticalCenter: parent.verticalCenter; x: Theme.px(70); width: col.width - Theme.px(140); frac: Number(modelData.tokens) / panel.maxTokens(panel.usage.days) }
                Value { text: panel.fmt(modelData.tokens); anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter } } }
        Rectangle { width: parent.width; height: 1; color: "#33ffffff" }

        Label { text: "TOKENS BY MODEL" }
        Text { visible: !(panel.usage && panel.usage.models && panel.usage.models.length); text: "No sessions in the last 7 days"; color: "#9a9aa2"; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont }
        Repeater { model: panel.usage && panel.usage.models ? panel.usage.models : []
            Rectangle { width: col.width; height: Theme.px(30); radius: Theme.px(6); color: "#2a2a30"
                Text { text: modelData.name; color: "#e6e6ea"; font.pixelSize: Theme.fpx(13); font.family: Theme.uiFont; anchors.left: parent.left; anchors.leftMargin: Theme.px(10); anchors.verticalCenter: parent.verticalCenter }
                Value { text: panel.fmt(modelData.tokens); anchors.right: parent.right; anchors.rightMargin: Theme.px(10); anchors.verticalCenter: parent.verticalCenter } } }
    }
    Timer { interval: 60000; running: panel.visible; repeat: true; onTriggered: AgentUsage.refresh() }
    onVisibleChanged: if (visible) AgentUsage.refresh()
}
