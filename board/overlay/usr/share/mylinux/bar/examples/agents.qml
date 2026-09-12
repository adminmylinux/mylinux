import QtQuick
import MyShell

// Example QML bar module: Claude Code / Codex sign-in state and the Claude session limit, from the AgentUsage
// singleton. Any MyShell singleton (Theme, Weather, Tailscale, Settings, Launcher) is available here.
Row {
    spacing: Theme.px(6)
    readonly property var claude: AgentUsage.claude
    readonly property var codex: AgentUsage.codex
    readonly property var session: claude && claude.limits ? claude.limits.find(l => l.label === "Session") : null
    Text { text: "✳"; color: claude && claude.signedIn ? Theme.text : "#9a9aa2"; font.pixelSize: Theme.fpx(13); anchors.verticalCenter: parent.verticalCenter }
    Text { text: session && session.pct >= 0 ? Math.round(session.pct * 100) + "%" : (claude && claude.signedIn ? "" : "—")
           color: session && session.pct > 0.8 ? "#ff6b6b" : Theme.text; font.pixelSize: Theme.fpx(12); font.family: Theme.monoFont; anchors.verticalCenter: parent.verticalCenter }
    Text { text: "◎"; color: codex && codex.signedIn ? Theme.text : "#9a9aa2"; font.pixelSize: Theme.fpx(13); anchors.verticalCenter: parent.verticalCenter }
    Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: AgentUsage.refresh() }
}
