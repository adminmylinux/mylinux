import QtQuick
import MyShell

// Proxmox status: running/total VMs and containers, node CPU and memory, from /api2/json/cluster/resources.
// Needs an API token saved as PROXMOX_API_TOKEN in the Settings panel (gear icon), in Proxmox's form
// user@realm!name=uuid, with the PVEAuditor role on / (read-only):
//   pveum user token add root@pam mylinux --privsep 1        (prints the uuid once)
//   pveum acl modify / --tokens 'root@pam!mylinux' --roles PVEAuditor
// The descriptor (proxmox.json) carries "url" (https://host:8006), "interval" seconds and "insecure" for a
// self-signed certificate. Click opens the web UI in the browser.
Item {
    id: pve
    readonly property var cfg: parent.mod.options
    readonly property string url: cfg.url || "https://192.168.0.200:8006"
    property string text: "▣ …"
    property string tip: "Proxmox: loading"
    property color color: Theme.text
    property bool problem: false
    width: label.implicitWidth + Theme.px(8); height: Theme.px(24)

    function refresh() {
        const token = Secrets.get("PROXMOX_API_TOKEN")
        if (!token.length) { text = "▣ no token"; tip = "Save a Proxmox API token as PROXMOX_API_TOKEN in Settings (see proxmox.qml)"; problem = true; return }
        Http.get(url + "/api2/json/cluster/resources", { "Authorization": "PVEAPIToken=" + token }, { insecure: !!cfg.insecure, timeout: 8000 }, function(status, body, err) {
            if (status !== 200) { text = "▣ " + (status === 401 ? "401" : status === 0 ? "offline" : String(status)); tip = "Proxmox " + url + ": " + (err || "HTTP " + status); problem = true; BarModules.report("proxmox", text, tip); return }
            let data
            try { data = JSON.parse(body).data } catch (e) { text = "▣ ?"; tip = "Proxmox: unreadable answer"; problem = true; return }
            const vms = data.filter(r => r.type === "qemu"), cts = data.filter(r => r.type === "lxc"), nodes = data.filter(r => r.type === "node")
            const run = xs => xs.filter(x => x.status === "running").length
            const stopped = vms.concat(cts).filter(x => x.status !== "running").map(x => x.name)
            let cpu = 0, mem = 0, maxmem = 0
            for (const n of nodes) { cpu += (n.cpu || 0) * (n.maxcpu || 1); mem += n.mem || 0; maxmem += n.maxmem || 0 }
            const cores = nodes.reduce((a, n) => a + (n.maxcpu || 0), 0) || 1
            const cpuPct = Math.round(cpu / cores * 100), memPct = maxmem ? Math.round(mem / maxmem * 100) : 0
            const down = nodes.filter(n => n.status !== "online").map(n => n.node)
            text = "▣ " + run(vms) + "/" + vms.length + " VM · " + run(cts) + "/" + cts.length + " CT · " + cpuPct + "% · " + memPct + "%"
            tip = "Proxmox " + nodes.map(n => n.node + (n.status === "online" ? "" : " (" + n.status + ")")).join(", ")
                + "\ncpu " + cpuPct + "% of " + cores + " cores · memory " + memPct + "% of " + Math.round(maxmem / 1073741824) + " GB"
                + (stopped.length ? "\nstopped: " + stopped.join(", ") : "\nall guests running")
            problem = down.length > 0
            BarModules.report("proxmox", text, tip)
        })
    }
    Text { id: label; anchors.centerIn: parent; anchors.verticalCenterOffset: Theme.px(2); text: pve.text; color: pve.problem ? "#f0c674" : Theme.text; font.pixelSize: Theme.fpx(12); font.family: Theme.uiFont }
    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; onClicked: Launcher.launch("/usr/bin/chromium", [pve.url]) }
    Rectangle { visible: ma.containsMouse; anchors.top: parent.bottom; anchors.topMargin: Theme.px(6); anchors.right: parent.right; z: 50
                width: tipText.implicitWidth + Theme.px(16); height: tipText.implicitHeight + Theme.px(10); radius: Theme.px(6); color: "#e0202126"; border.color: "#44ffffff"
                Text { id: tipText; anchors.centerIn: parent; text: pve.tip; color: "#e6e6ea"; font.pixelSize: Theme.fpx(11); font.family: Theme.uiFont } }
    Timer { interval: Math.max(5, Number(pve.cfg.interval) || 30) * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: pve.refresh() }
    Connections { target: Secrets; function onChanged() { pve.refresh() } }
}
