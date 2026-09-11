#!/usr/bin/env python3
"""myLinux VM smoke tests: boot the throwaway test VM (tools/fresh-start.sh keep), drive it through
QEMU's QMP socket and the serial console, and assert on the compositor's diagnostics dump.

    tools/vmtest/vmtest.py                run every scenario
    tools/vmtest/vmtest.py typing focus   run some, by name
    tools/vmtest/vmtest.py --keep         leave the VM running afterwards

Uses out/apps-fresh.img and out/fresh-share only. Never touches the user's disk or share.
Assertions have deadlines; screenshots are saved next to a failing step for inspection only.
"""
import json, os, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "out")
SHARE = os.path.join(OUT, "fresh-share")
QMP = os.path.join(OUT, "qmp-test.sock")
SERIAL = os.path.join(OUT, "serial-test.sock")
QMP_PY = os.path.join(ROOT, "tools", "qmp.py")
SERIAL_PY = os.path.join(ROOT, "tools", "serial.py")


class Fail(Exception):
    pass


class VM:
    def __init__(self):
        self.res = None
        self.proc = None

    # ---- lifecycle ----
    def boot(self, timeout=90):
        os.makedirs(SHARE, exist_ok=True)
        ini = os.path.join(SHARE, "mylinux.ini")
        text = open(ini).read() if os.path.exists(ini) else ""
        if "[test]" not in text:
            text += "\n[test]\ndiag=true\n"
        # the scenarios type US-layout characters; the share is disposable, so pin the layout
        import re
        text = re.sub(r"(?m)^layout=.*$", "layout=us", text)
        if "layout=us" not in text: text += "\n[input]\nlayout=us\n"
        open(ini, "w").write(text)
        for p in (QMP, SERIAL, os.path.join(SHARE, "diag.json"), os.path.join(SHARE, "diag-request")):
            if os.path.exists(p): os.remove(p)
        subprocess.run(["pkill", "-f", "apps-fresh.img"], capture_output=True)
        time.sleep(1)
        env = dict(os.environ, SERIAL=f"unix:{SERIAL},server,nowait")
        self.proc = subprocess.Popen([os.path.join(ROOT, "tools", "fresh-start.sh"), "keep", "-qmp", f"unix:{QMP},server,nowait"],
                                     cwd=ROOT, env=env, stdout=open(os.path.join(OUT, "vmtest-boot.log"), "w"), stderr=subprocess.STDOUT)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(QMP) and os.path.exists(SERIAL):
                try:
                    d = self.diag(timeout=5)
                    if d is not None:
                        self.res = self._res()
                        return
                except Fail:
                    pass
            time.sleep(2)
        raise Fail("VM did not come up (no diagnostics within %ds)" % timeout)

    def _res(self):
        out = subprocess.run(["sh", "-c", "ps -o args= -p $(pgrep -f apps-fresh.img | head -1) | grep -o 'mylinux.res=[0-9x]*'"],
                             capture_output=True, text=True).stdout.strip()
        return out.split("=")[1] if "=" in out else "1688x1016"

    def stop(self, pattern="apps-fresh.img"):
        """Clean shutdown first (a killed QEMU is a power cut: files rewritten just before it can come back
        empty on the test disk), then a kill if the guest does not power off within 30 s."""
        try:
            if os.path.exists(SERIAL): self.serial("poweroff", 1)
        except Exception:
            pass
        for _ in range(30):
            if subprocess.run(["pgrep", "-f", pattern], capture_output=True).returncode != 0: return
            time.sleep(1)
        subprocess.run(["pkill", "-f", pattern], capture_output=True)

    # ---- input / output ----
    def qmp(self, *ops):
        env = dict(os.environ, SCREEN=self.res or "1688x1016")
        r = subprocess.run([sys.executable, QMP_PY, QMP] + [str(o) for o in ops], capture_output=True, text=True, env=env)
        if r.returncode != 0:
            raise Fail("qmp failed: " + r.stderr.strip()[-200:])

    def serial(self, cmd, settle=3):
        r = subprocess.run([sys.executable, SERIAL_PY, SERIAL, str(settle), cmd], capture_output=True, text=True)
        return r.stdout

    def shot(self, name):
        path = os.path.join(OUT, "vmtest-%s.png" % name)
        self.qmp("shot", path)
        return path

    def diag(self, timeout=6):
        """Ask the compositor for its window inventory (needs [test] diag=true in the share ini)."""
        req = os.path.join(SHARE, "diag-request"); res = os.path.join(SHARE, "diag.json")
        if os.path.exists(res): os.remove(res)
        open(req, "w").close()
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(res):
                try:
                    return json.load(open(res))
                except json.JSONDecodeError:
                    pass
            time.sleep(0.25)
        return None

    def wait_for(self, pred, what, timeout=20):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = self.diag()
            if last and pred(last):
                return last
            time.sleep(0.7)
        raise Fail("timeout waiting for %s; last diag: %s" % (what, json.dumps(last)[:600] if last else None))

    def reset(self):
        """Close stray terminals and Firefox, hide the scratchpad, go to workspace 1."""
        self.serial("killall foot firefox-esr 2>/dev/null; echo", 2)
        d = self.diag()
        if d and d.get("scratchVisible"): self.qmp("combo", "meta_l-s", "sleep", 0.5)
        self.qmp("combo", "meta_l-1", "sleep", 0.6)

    def windows(self, d, **match):
        return [w for w in d["windows"] if all(str(w.get(k)) == str(v) for k, v in match.items())]


# ---------------------------------------------------------------- scenarios
def scenario_boot(vm):
    d = vm.wait_for(lambda d: len(vm.windows(d, helper=False)) >= 1, "at least one autostart window", 60)
    assert d["workspace"] == 1


def scenario_foot_typing(vm):
    vm.qmp("combo", "meta_l-2", "sleep", 0.5, "combo", "meta_l-ret")
    vm.wait_for(lambda d: d["workspace"] == 2 and any(w["appId"] == "foot" and w["mapped"] for w in d["windows"]), "terminal on workspace 2")
    marker = "vmtest-%d" % int(time.time())
    vm.qmp("type", "echo %s > /mnt/share/typed.txt\n" % marker, "sleep", 1.5)
    p = os.path.join(SHARE, "typed.txt")
    if not os.path.exists(p) or marker not in open(p).read():
        raise Fail("typed text did not reach the terminal")
    os.remove(p)
    vm.qmp("combo", "meta_l-w", "sleep", 0.8)


def ensure_firefox(vm):
    """Firefox ESR on the test disk (installed on first use, like the dock icon does; a few minutes once)."""
    def present():
        p = os.path.join(SHARE, "vmtest", "ff-present")
        if os.path.exists(p): os.remove(p)
        vm.serial("apps-run test -x /usr/bin/firefox-esr && touch /mnt/share/vmtest/ff-present; echo", 2)
        time.sleep(0.5)
        return os.path.exists(p)
    if present(): return
    marker = os.path.join(SHARE, "vmtest", "ff-install.done")
    if os.path.exists(marker): os.remove(marker)
    vm.serial("setsid sh -c 'apps-run env DEBIAN_FRONTEND=noninteractive dpkg --configure -a; apps-run apt-get update -q && apps-run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends firefox-esr; apps-path; echo rc=$? > /mnt/share/vmtest/ff-install.done' < /dev/null > /var/log/vmtest-ff.log 2>&1 &", 2)
    deadline = time.time() + 600
    while time.time() < deadline:
        if os.path.exists(marker): break
        time.sleep(5)
    if not present():
        vm.serial("cp /var/log/vmtest-ff.log /mnt/share/vmtest/ff-install.log; echo", 2)
        raise Fail("Firefox could not be installed on the test disk (see out/fresh-share/vmtest/ff-install.log)")


def scenario_firefox_typing(vm):
    ensure_firefox(vm)
    # a throwaway profile: no session restore, no "Troubleshoot Mode?" prompt after a killed instance
    vm.serial("killall firefox-esr 2>/dev/null; rm -rf /tmp/vmtest-ffprof; mkdir -p /tmp/vmtest-ffprof; cd /root; env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 MOZ_DISABLE_AUTO_SAFE_MODE=1 setsid apps-run firefox-esr --no-remote --profile /tmp/vmtest-ffprof file:///mnt/share/vmtest/typing.html >/dev/null 2>&1 </dev/null &", 2)
    d = vm.wait_for(lambda d: any(w["appId"] == "firefox-esr" and w["mapped"] and "typing-fixture" in w["title"] for w in d["windows"]), "Firefox with the fixture", 40)
    w = [w for w in d["windows"] if w["appId"] == "firefox-esr" and "typing-fixture" in w["title"]][0]
    # click into the page body then into the textarea (page centre is safe on a half or full tile)
    vm.qmp("click", d["layerX"] + w["x"] + w["width"] // 2, d["layerY"] + w["y"] + w["height"] // 2, "sleep", 0.6)
    vm.qmp("type", "hello", "sleep", 1.2)
    d = vm.wait_for(lambda d: any("typing-fixture:hello" in w["title"] for w in d["windows"]), "typed text in Firefox title", 10)
    vm.serial("killall firefox-esr", 2)


def scenario_empty_workspace_focus(vm):
    vm.qmp("combo", "meta_l-9", "sleep", 0.8)
    d = vm.wait_for(lambda d: d["workspace"] == 9, "workspace 9")
    if not d["seatFocusNull"]:
        raise Fail("empty workspace but the seat still has keyboard focus on %s" % d.get("seatFocus"))
    vm.qmp("combo", "meta_l-1", "sleep", 0.8)
    d = vm.wait_for(lambda d: d["workspace"] == 1, "back on workspace 1")
    if d["seatFocusNull"] and vm.windows(d, helper=False, workspace=1, minimized=False):
        raise Fail("back on workspace 1 with windows but nothing focused")


def scenario_helper_not_tiled(vm):
    # a wl-clipboard helper (mac -> guest copy) must never enter the tiling tree or the window lists
    d0 = vm.diag()
    mac_clipboard(b"vmtest clip %d" % int(time.time()))
    time.sleep(2.5)
    # toggle tiling off and on: helpers and scratchpad windows must stay out of the trees
    vm.qmp("combo", "shift-meta_l-t", "sleep", 0.8, "combo", "shift-meta_l-t", "sleep", 1.2)
    d = vm.diag()
    bad = [w for w in d["windows"] if (w["helper"] or w["scratch"]) and (w["inTree"] or w["tiled"])]
    if bad:
        raise Fail("helper/scratch window in tiling: %s" % bad)
    leaves = [l for t in d["trees"] for l in t["leaves"]]
    if any(l.startswith("|") and "wl-clipboard" in l for l in leaves):
        raise Fail("wl-clipboard leaf in a tree: %s" % leaves)


def scenario_scratchpad(vm):
    vm.qmp("combo", "meta_l-2", "sleep", 0.5, "combo", "meta_l-ret")
    vm.wait_for(lambda d: d["workspace"] == 2 and any(w["appId"] == "foot" and w["mapped"] for w in d["windows"]), "terminal")
    vm.qmp("combo", "alt-meta_l-s", "sleep", 1)
    d = vm.diag()
    s = [w for w in d["windows"] if w["appId"] == "foot" and w["scratch"]]
    if not s or s[0]["inTree"] or s[0]["visible"]:
        raise Fail("window not moved to a hidden, floating scratchpad: %s" % s)
    vm.qmp("combo", "meta_l-s", "sleep", 1)
    d = vm.diag()
    s = [w for w in d["windows"] if w["appId"] == "foot" and w["scratch"]]
    if not s or not s[0]["visible"] or s[0]["inTree"]:
        raise Fail("scratchpad window not shown floating: %s" % s)
    vm.qmp("combo", "shift-meta_l-t", "sleep", 0.8, "combo", "shift-meta_l-t", "sleep", 1)
    d = vm.diag()
    if any(w["scratch"] and w["inTree"] for w in d["windows"]):
        raise Fail("scratchpad window entered tiling after a tiling toggle")
    vm.qmp("combo", "meta_l-w", "sleep", 0.8, "combo", "meta_l-1", "sleep", 0.5)


def mac_clipboard(data):
    """What run.sh's host loop does: byte-exact mac.txt, then bump mac.seq (the guest bridge applies new sequences)."""
    d = os.path.join(SHARE, "clipboard"); os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "mac.txt"); s = os.path.join(d, "mac.seq")
    open(p + ".tmp", "wb").write(data); os.replace(p + ".tmp", p)
    try: n = int(open(s).read().strip())
    except Exception: n = 0
    open(s + ".tmp", "w").write("%d\n" % (n + 1)); os.replace(s + ".tmp", s)


def scenario_clipboard_fidelity(vm):
    """Mac -> guest text arrives byte-exact (Unicode, blank lines, trailing newline) and focus stays where it was."""
    d0 = vm.wait_for(lambda d: d["focused"] is not None, "a focused window", 10)
    text = ("vmtest ünïcödé — 日本語 🎉 $(not run) `x`\n\nline three  \n").encode("utf-8")
    mac_clipboard(text)
    out = os.path.join(SHARE, "vmtest", "pasted.txt")
    if os.path.exists(out): os.remove(out)
    deadline = time.time() + 15; got = None
    while time.time() < deadline:
        vm.serial("env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 apps-run wl-paste -n -t text/plain > /mnt/share/vmtest/pasted.txt 2>/dev/null; echo", 2)
        if os.path.exists(out):
            got = open(out, "rb").read()
            if got == text: break
        time.sleep(1)
    if got != text:
        raise Fail("pasted bytes differ: got %r" % (got[:80] if got else got))
    d = vm.diag()
    if d["focused"] != d0["focused"] or (d.get("seatFocus") or "").endswith("|helper"):
        raise Fail("focus changed by the clipboard helper: before %s, after %s (seat %s)" % (d0["focused"], d["focused"], d.get("seatFocus")))
    # the same sequence again must not re-copy (bridge state), a new one with the same bytes must
    n_before = vm.serial("grep -c . /var/log/clipboard.log 2>/dev/null; echo", 1)
    mac_clipboard(text); time.sleep(2)
    vm.serial("env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 apps-run wl-paste -n -t text/plain > /mnt/share/vmtest/pasted.txt 2>/dev/null; echo", 2)
    if open(out, "rb").read() != text:
        raise Fail("clipboard content changed after an identical re-copy")


def scenario_spotlight_keeps_focus(vm):
    """Keys typed into the open menu stay there even when a clipboard helper window comes and goes."""
    _open_terminal(vm, 2)
    vm.qmp("combo", "meta_l-spc", "sleep", 0.8)
    d = vm.wait_for(lambda d: d["seatFocusNull"], "seat focus released to the menu", 5)
    leak = os.path.join(SHARE, "leak.txt")
    if os.path.exists(leak): os.remove(leak)
    mac_clipboard(b"vmtest focus %d" % int(time.time()))      # wl-copy helper maps, takes focus briefly, disappears
    time.sleep(2.5)
    vm.qmp("type", "echo leaked > /mnt/share/leak.txt\n", "sleep", 1.5)
    d = vm.diag()
    if os.path.exists(leak):
        raise Fail("typing went to the terminal instead of the open menu")
    if not d["seatFocusNull"]:
        raise Fail("an app has keyboard focus while the menu is open: %s" % d.get("seatFocus"))
    vm.qmp("key", "esc", "sleep", 0.5, "combo", "meta_l-w", "sleep", 0.6, "combo", "meta_l-1", "sleep", 0.5)


def scenario_menu_shortcuts(vm):
    """Every binding of the menu opens it: ⌘Space, ⌘Esc, ⌘D; Esc closes it. ⌘8 still switches workspaces."""
    for combo in ("meta_l-spc", "meta_l-esc", "meta_l-d"):
        vm.qmp("combo", combo, "sleep", 0.8)
        vm.wait_for(lambda d: d["menuOpen"], "menu open after %s" % combo, 6)
        vm.qmp("key", "esc", "sleep", 0.6)
        vm.wait_for(lambda d: not d["menuOpen"], "menu closed after Esc", 6)
    # arrows walk the categories: → opens the selected one, ← returns to the top level
    vm.qmp("combo", "meta_l-spc", "sleep", 0.8, "key", "right", "sleep", 0.5)
    vm.wait_for(lambda d: d["menuOpen"] and d["menuDepth"] == 1, "submenu opened with the right arrow", 6)
    vm.qmp("key", "left", "sleep", 0.5)
    vm.wait_for(lambda d: d["menuOpen"] and d["menuDepth"] == 0, "back at the top level with the left arrow", 6)
    vm.qmp("key", "esc", "sleep", 0.6)
    vm.wait_for(lambda d: not d["menuOpen"], "menu closed", 6)
    vm.qmp("combo", "meta_l-8", "sleep", 0.6)
    vm.wait_for(lambda d: d["workspace"] == 8 and not d["menuOpen"], "workspace 8", 6)
    vm.qmp("combo", "meta_l-1", "sleep", 0.6)


def scenario_shell_restart(vm):
    """/etc/init.d/S99shell restart brings the compositor back with the autostart windows, diagnostics answering."""
    vm.serial("/etc/init.d/S99shell restart; echo", 2)
    time.sleep(4)
    d = vm.wait_for(lambda d: len(vm.windows(d, helper=False)) >= 1 and d["workspace"] == 1, "shell back with a window after restart", 60)
    if d["seatFocusNull"] and vm.windows(d, helper=False, mapped=True):
        raise Fail("windows present after the restart but nothing focused")


def scenario_close_button(vm):
    vm.qmp("combo", "meta_l-2", "sleep", 0.5, "combo", "meta_l-ret")
    d = vm.wait_for(lambda d: d["workspace"] == 2 and any(w["appId"] == "foot" and w["mapped"] for w in d["windows"]), "terminal")
    w = [w for w in d["windows"] if w["appId"] == "foot"][0]
    vm.qmp("click", d["layerX"] + w["x"] + 18, d["layerY"] + w["y"] + 17, "sleep", 1.2)   # red traffic light (screen coordinates)
    vm.wait_for(lambda d: not any(x["appId"] == "foot" and x["workspace"] == 2 for x in d["windows"]), "terminal closed by its red button", 8)
    vm.qmp("combo", "meta_l-1", "sleep", 0.5)


def _open_terminal(vm, ws, count=1, timeout=20):
    """Open `count` terminals on workspace `ws`; returns the diag once they are all mapped."""
    vm.qmp("combo", "meta_l-%d" % ws, "sleep", 0.5)
    for _ in range(count):
        vm.qmp("combo", "meta_l-ret", "sleep", 0.3)
    return vm.wait_for(lambda d: d["workspace"] == ws and len([w for w in d["windows"] if w["appId"] == "foot" and w["mapped"] and w["workspace"] == ws]) >= count,
                       "%d terminal(s) on workspace %d" % (count, ws), timeout)


def _no_overlap(d, ws):
    """Tiled, visible windows on a workspace must have non-negative rects inside the work area and not overlap."""
    tiles = [w for w in d["windows"] if w["workspace"] == ws and w["tiled"] and w["visible"] and not w["helper"]]
    for w in tiles:
        if w["width"] <= 0 or w["height"] <= 0 or w["x"] < 0 or w["y"] < 0:
            raise Fail("degenerate tile rect: %s" % w)
        if w["x"] + w["width"] > d["layerW"] + 2 or w["y"] + w["height"] > d["layerH"] + 2:
            raise Fail("tile outside the work area (%dx%d): %s" % (d["layerW"], d["layerH"], w))
    for i, a in enumerate(tiles):
        for b in tiles[i + 1:]:
            if a["x"] < b["x"] + b["width"] - 1 and b["x"] < a["x"] + a["width"] - 1 and a["y"] < b["y"] + b["height"] - 1 and b["y"] < a["y"] + a["height"] - 1:
                raise Fail("overlapping tiles: %s and %s" % (a["title"], b["title"]))
    return tiles


def scenario_fullscreen(vm):
    d = _open_terminal(vm, 3)
    foot = lambda d: [w for w in d["windows"] if w["appId"] == "foot" and w["workspace"] == 3]
    if not foot(d)[0]["inTree"]:
        raise Fail("terminal did not start tiled: %s" % foot(d))
    vm.qmp("combo", "meta_l-f", "sleep", 0.5)
    d = vm.wait_for(lambda d: foot(d) and foot(d)[0]["fullscreen"] and foot(d)[0]["clientFullscreen"], "fullscreen acknowledged by the client", 10)
    w = foot(d)[0]
    if w["inTree"] or w["tiled"]:
        raise Fail("fullscreen window still in the tiling tree: %s" % w)
    if w["x"] != 0 or w["y"] != 0 or w["titleHeight"] != 0 or abs(w["width"] - d["layerW"]) > 2 or abs(w["height"] - d["layerH"]) > 2:
        raise Fail("fullscreen window does not cover the work area %dx%d: %s" % (d["layerW"], d["layerH"], w))
    # a window opened while another is fullscreen: tiled normally, activation moves to it, fullscreen one keeps its state
    vm.qmp("combo", "meta_l-ret", "sleep", 0.5)
    d = vm.wait_for(lambda d: len([w for w in foot(d) if w["mapped"]]) >= 2, "second terminal", 15)
    d = vm.wait_for(lambda d: [w for w in foot(d) if w["clientActivated"]] and all(w["clientActivated"] == w["focused"] for w in foot(d)),
                    "exactly the focused window activated", 10)
    fs = [w for w in foot(d) if w["fullscreen"]]; other = [w for w in foot(d) if not w["fullscreen"]]
    if len(fs) != 1 or len(other) != 1 or not other[0]["inTree"] or not fs[0]["clientFullscreen"]:
        raise Fail("state after opening a second window: fullscreen=%s other=%s" % (fs, other))
    # close the new one: focus returns to the fullscreen window; leave fullscreen -> back into its tree
    vm.qmp("combo", "meta_l-w", "sleep", 0.8)
    d = vm.wait_for(lambda d: len(foot(d)) == 1 and foot(d)[0]["focused"], "focus back on the fullscreen window", 10)
    vm.qmp("combo", "meta_l-f", "sleep", 0.5)
    d = vm.wait_for(lambda d: foot(d) and not foot(d)[0]["fullscreen"] and not foot(d)[0]["clientFullscreen"] and foot(d)[0]["inTree"], "restored into the tiling tree", 10)
    _no_overlap(d, 3)
    vm.qmp("combo", "meta_l-w", "sleep", 0.8, "combo", "meta_l-1", "sleep", 0.5)


def scenario_single_activation(vm):
    d = _open_terminal(vm, 3, 2)
    foot = lambda d: [w for w in d["windows"] if w["appId"] == "foot" and w["workspace"] == 3]
    d = vm.wait_for(lambda d: len([w for w in foot(d) if w["clientActivated"]]) == 1 and all(w["clientActivated"] == w["focused"] for w in foot(d)),
                    "one activated terminal", 10)
    before = [w for w in foot(d) if w["focused"]][0]["title"]
    # move focus with ⌘← / ⌘→ (whichever side the neighbour is on): the old window must drop ActivatedState
    vm.qmp("combo", "meta_l-left", "sleep", 0.4, "combo", "meta_l-right", "sleep", 0.4, "combo", "meta_l-left", "sleep", 0.6)
    d = vm.wait_for(lambda d: len([w for w in foot(d) if w["clientActivated"]]) == 1 and all(w["clientActivated"] == w["focused"] for w in foot(d)),
                    "still exactly one activated terminal after moving focus", 10)
    _no_overlap(d, 3)
    vm.qmp("combo", "meta_l-w", "sleep", 0.6, "combo", "meta_l-w", "sleep", 0.6, "combo", "meta_l-1", "sleep", 0.5)


def scenario_scale_relayout(vm):
    d = _open_terminal(vm, 3, 2)
    d = vm.wait_for(lambda d: len([w for w in d["windows"] if w["appId"] == "foot" and w["workspace"] == 3 and w["inTree"]]) == 2, "two tiled terminals", 10)
    scale0 = d["scale"]
    vm.qmp("combo", "meta_l-1", "sleep", 0.5)                      # workspace 3's tree is now hidden
    vm.qmp("combo", "meta_l-slash", "sleep", 1.5)                  # scale up: every tree must be relaid, not only the visible one
    d = vm.wait_for(lambda d: d["scale"] > scale0, "scale increased", 8)
    _no_overlap(d, 1)
    vm.qmp("combo", "meta_l-3", "sleep", 1.2)
    d = vm.wait_for(lambda d: d["workspace"] == 3, "workspace 3")
    tiles = _no_overlap(d, 3)
    if len(tiles) != 2:
        raise Fail("expected two tiles on workspace 3 after the scale change, got %s" % [t["title"] for t in tiles])
    vm.qmp("combo", "alt-meta_l-slash", "sleep", 1.5)
    d = vm.wait_for(lambda d: abs(d["scale"] - scale0) < 0.01, "scale restored", 8)
    _no_overlap(d, 3)
    vm.qmp("combo", "meta_l-w", "sleep", 0.6, "combo", "meta_l-w", "sleep", 0.6, "combo", "meta_l-1", "sleep", 0.5)


def scenario_client_fullscreen(vm):
    """A client's own fullscreen request (Firefox F11) goes through the same state path as ⌘F."""
    ensure_firefox(vm)

    vm.serial("killall firefox-esr 2>/dev/null; rm -rf /tmp/vmtest-ffprof; mkdir -p /tmp/vmtest-ffprof; cd /root; env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 MOZ_DISABLE_AUTO_SAFE_MODE=1 setsid apps-run firefox-esr --no-remote --profile /tmp/vmtest-ffprof file:///mnt/share/vmtest/typing.html >/dev/null 2>&1 </dev/null &", 2)
    ff = lambda d: [w for w in d["windows"] if w["appId"] == "firefox-esr" and "typing-fixture" in w["title"]]
    d = vm.wait_for(lambda d: ff(d) and ff(d)[0]["mapped"], "Firefox with the fixture", 40)
    w = ff(d)[0]
    vm.qmp("click", d["layerX"] + w["x"] + w["width"] // 2, d["layerY"] + w["y"] + w["height"] // 2, "sleep", 0.6, "key", "f11", "sleep", 1)
    d = vm.wait_for(lambda d: ff(d) and ff(d)[0]["fullscreen"] and ff(d)[0]["clientFullscreen"] and not ff(d)[0]["inTree"], "Firefox fullscreen on its own request", 15)
    w = ff(d)[0]
    if w["x"] != 0 or w["y"] != 0 or abs(w["width"] - d["layerW"]) > 2:
        raise Fail("client-requested fullscreen does not cover the work area: %s" % w)
    vm.qmp("key", "f11", "sleep", 1)
    d = vm.wait_for(lambda d: ff(d) and not ff(d)[0]["fullscreen"] and not ff(d)[0]["clientFullscreen"] and ff(d)[0]["inTree"], "Firefox back in its tile after leaving fullscreen", 15)
    vm.serial("killall firefox-esr", 2)


def scenario_agent_usage_fixtures(vm):
    """AgentUsage's scanner and limits parser on synthetic logs, run in the guest through the shell binary's test hooks."""
    fx = os.path.join(SHARE, "vmtest", "agent")
    if os.path.exists(fx): subprocess.run(["rm", "-rf", fx])
    subprocess.run(["cp", "-R", os.path.join(ROOT, "tools", "vmtest", "fixtures", "agent"), fx], check=True)
    binary = "/mnt/share/myshell" if os.path.exists(os.path.join(SHARE, "myshell")) else "/usr/bin/myshell"
    vm.serial("%s --agent-scan /mnt/share/vmtest/agent 2026-09-10 > /mnt/share/vmtest/agent/scan1.json 2>/dev/null; sleep 1; %s --agent-scan /mnt/share/vmtest/agent 2026-09-10 > /mnt/share/vmtest/agent/scan2.json 2>/dev/null; %s --claude-limits /mnt/share/vmtest/agent/limits-fractions.json > /mnt/share/vmtest/agent/limits.json 2>/dev/null; echo done" % (binary, binary, binary), 6)
    try:
        s1 = json.load(open(os.path.join(fx, "scan1.json"))); s2 = json.load(open(os.path.join(fx, "scan2.json"))); lim = json.load(open(os.path.join(fx, "limits.json")))
    except Exception as e:
        raise Fail("scan output unreadable: %r" % e)
    c = s1["claude"]
    days = {r["label"]: r["tokens"] for r in c["days"]}
    if len(c["days"]) != 7: raise Fail("expected 7 day rows, got %d" % len(c["days"]))
    if days["Today"] != 200: raise Fail("today's Claude tokens: streamed duplicate must count once (200), got %s" % days["Today"])
    total = sum(r["tokens"] for r in c["days"])
    if total != 1200: raise Fail("seven-day window must include 2026-09-04 and exclude 2026-09-03: total %s, wanted 1200" % total)
    models = {r["name"]: r["tokens"] for r in c["models"]}
    if models.get("Fable 5.1") != 200 or "Opus 4.5" not in models: raise Fail("model rows wrong: %s" % models)
    x = s1["codex"]
    xd = {r["label"]: r["tokens"] for r in x["days"]}
    if xd["Today"] != 470: raise Fail("Codex today tokens: %s (wanted 470)" % xd["Today"])
    L = {l["label"]: l for l in x["limits"]}
    if L["Session"]["resetsAt"] != "2026-09-10T08:00:10Z" or L["Weekly"]["resetsAt"] != "2026-09-11T07:00:10Z":
        raise Fail("Codex reset times must be anchored to the log timestamp: %s" % L)
    if abs(L["Session"]["pct"] - 0.125) > 1e-6: raise Fail("Codex used_percent is a percent: %s" % L["Session"])
    if s2["codex"]["limits"] != x["limits"]: raise Fail("a second scan of unchanged logs moved the reset deadline: %s vs %s" % (s2["codex"]["limits"], x["limits"]))
    if s2["claude"]["days"] != c["days"]: raise Fail("second scan differs from the first")
    if s1["cachedFiles"] != 2: raise Fail("cache should hold both log files, has %s" % s1["cachedFiles"])
    P = {l["label"]: l["pct"] for l in lim}
    if abs(P["Session"] - 0.005) > 1e-9 or abs(P["Weekly"] - 0.0025) > 1e-9: raise Fail("utilization below 1 must still read as percent (0.5 -> 0.5%%): %s" % P)
    if abs(P["Opus Weekly"] - 0.0075) > 1e-9: raise Fail("percent field below 1: %s" % P)
    if P.get("Sonnet Weekly") != -1: raise Fail("an unknown field must give 'unknown' (-1), got %s" % P.get("Sonnet Weekly"))


SCENARIOS = [
    ("boot", scenario_boot),
    ("foot_typing", scenario_foot_typing),
    ("firefox_typing", scenario_firefox_typing),
    ("empty_workspace_focus", scenario_empty_workspace_focus),
    ("helper_not_tiled", scenario_helper_not_tiled),
    ("scratchpad", scenario_scratchpad),
    ("close_button", scenario_close_button),
    ("fullscreen", scenario_fullscreen),
    ("single_activation", scenario_single_activation),
    ("scale_relayout", scenario_scale_relayout),
    ("client_fullscreen", scenario_client_fullscreen),
    ("agent_usage_fixtures", scenario_agent_usage_fixtures),
    ("clipboard_fidelity", scenario_clipboard_fidelity),
    ("shell_restart", scenario_shell_restart),
    ("spotlight_keeps_focus", scenario_spotlight_keeps_focus),
    ("menu_shortcuts", scenario_menu_shortcuts),
]






def main(argv):
    keep = "--keep" in argv
    names = [a for a in argv if not a.startswith("--")]
    todo = [(n, f) for n, f in SCENARIOS if not names or n in names]
    # fixtures into the share
    fx = os.path.join(SHARE, "vmtest"); os.makedirs(fx, exist_ok=True)
    src = os.path.join(ROOT, "tools", "vmtest", "fixtures", "typing.html")
    open(os.path.join(fx, "typing.html"), "w").write(open(src).read())
    vm = VM()
    results = []
    try:
        print("booting test VM ..."); vm.boot(); print("up, resolution", vm.res)
        for name, fn in todo:
            t0 = time.time()
            try:
                if name != "boot": vm.reset()
                fn(vm); results.append((name, "PASS", "%.0fs" % (time.time() - t0)))
            except Fail as e:
                shot = vm.shot("fail-" + name)
                results.append((name, "FAIL", "%s (screenshot %s)" % (e, os.path.relpath(shot, ROOT))))
            except Exception as e:  # driver error, still a failure
                results.append((name, "ERROR", repr(e)))
            print("%-24s %s" % (name, results[-1][1]))
    except Fail as e:
        results.append(("boot", "FAIL", str(e)))
    finally:
        if not keep: vm.stop()
    print()
    for n, s, info in results: print("%-24s %-5s %s" % (n, s, info))
    failed = [r for r in results if r[1] != "PASS"]
    print("\n%d scenario(s), %d failed" % (len(results), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
