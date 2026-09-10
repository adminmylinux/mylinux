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

    def stop(self):
        subprocess.run(["pkill", "-f", "apps-fresh.img"], capture_output=True)

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


def scenario_firefox_typing(vm):
    if "ok" not in vm.serial("apps-run test -x /usr/bin/firefox-esr && echo ok", 3):
        raise Fail("Firefox not on the test disk (install it once: apps-run apt-get install firefox-esr)")
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
    os.makedirs(os.path.join(SHARE, "clipboard"), exist_ok=True)
    p = os.path.join(SHARE, "clipboard", "mac.txt")
    open(p + ".tmp", "w").write("vmtest clip %d" % int(time.time())); os.replace(p + ".tmp", p)
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
