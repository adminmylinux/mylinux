#!/usr/bin/env python3
"""Apps-disk lifecycle tests on the throwaway VM (review section 7). Needs a baked image (build.sh) since the
init scripts live in the rootfs. Never touches out/apps.img or share/.

    tools/vmtest/disktest.py            all scenarios
    tools/vmtest/disktest.py states     some, by name

states     the set-up test disk plus a foreign disk and a second blank disk: only ours is mounted, the others
           stay byte-identical, the legacy disk gets its ready marker, apps-run works
lock       a second apps-setup while one runs is refused; the first completes (repairs the legacy markers,
           reinstalls the agents from the manifest); status file and markers checked
shutdown   S45apps stop with a chroot program running: processes ended, every nested mount unwound
blank      (first) wipes the test disk: state blank, tailscaled on the volatile path; apps-setup interrupted during
           the desktop stage and run again -> completes, ready marker, stages, tailscaled on the disk
"""
import hashlib, json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vmtest
from vmtest import Fail, ROOT, OUT, SHARE, QMP, SERIAL

FOREIGN = os.path.join(OUT, "vmtest-foreign.img")
EXTRA_BLANK = os.path.join(OUT, "vmtest-extra-blank.img")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return h.hexdigest()


def make_disks():
    if not os.path.exists(FOREIGN):
        with open(FOREIGN, "wb") as f:
            f.truncate(64 << 20)
            f.seek(1080); f.write(b"\x53\xef")            # ext4 magic, label "data": readable, not ours
            f.seek(1144); f.write(b"data")
    if not os.path.exists(EXTRA_BLANK):
        with open(EXTRA_BLANK, "wb") as f: f.truncate(64 << 20)


class DiskVM(vmtest.VM):
    def __init__(self, apps_img=None, share=None, extra=()):
        super().__init__()
        self.apps_img = apps_img; self.share = share; self.extra = list(extra)

    def boot(self, timeout=120):
        share = self.share or SHARE
        os.makedirs(share, exist_ok=True)
        ini = os.path.join(share, "mylinux.ini")
        text = open(ini).read() if os.path.exists(ini) else ""
        if "[test]" not in text: text += "\n[test]\ndiag=true\n"
        open(ini, "w").write(text)
        for p in (QMP, SERIAL): 
            if os.path.exists(p): os.remove(p)
        subprocess.run(["pkill", "-f", "apps-fresh.img"], capture_output=True)
        subprocess.run(["pkill", "-f", "vmtest-blank.img"], capture_output=True)
        time.sleep(1)
        env = dict(os.environ, SERIAL=f"unix:{SERIAL},server,nowait")
        if self.apps_img: env["APPS_IMG"] = self.apps_img
        if self.share: env["SHARE_DIR"] = self.share
        env["NAME"] = "myLinux (test)"
        args = [os.path.join(ROOT, "run.sh") if self.apps_img else os.path.join(ROOT, "tools", "fresh-start.sh")]
        if not self.apps_img: args.append("keep")
        args += ["-qmp", f"unix:{QMP},server,nowait"] + self.extra
        self.proc = subprocess.Popen(args, cwd=ROOT, env=env, stdout=open(os.path.join(OUT, "disktest-boot.log"), "w"), stderr=subprocess.STDOUT)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(SERIAL) and "up" in self.serial("echo u\\p", 2):
                return
            time.sleep(2)
        raise Fail("VM did not come up")

    def stop(self):
        super().stop(os.path.basename(self.apps_img) if self.apps_img else "apps-fresh.img")

    def sh(self, cmd, settle=3):
        """Run a command in the guest, return its stdout+stderr (via a file on the share)."""
        share = self.share or SHARE
        out = os.path.join(share, "disktest.out")
        if os.path.exists(out): os.remove(out)
        self.serial("{ %s ; } > /mnt/share/disktest.out 2>&1; echo cmd-done" % cmd, settle)
        deadline = time.time() + settle + 10
        while time.time() < deadline:
            if os.path.exists(out):
                time.sleep(0.3)
                return open(out, errors="replace").read()
            time.sleep(0.3)
        return ""


def expect(cond, what):
    if not cond: raise Fail(what)


def scenario_states():
    make_disks()
    f0, b0 = sha(FOREIGN), sha(EXTRA_BLANK)
    extra = ["-drive", f"file={FOREIGN},if=none,format=raw,id=foreign", "-device", "virtio-blk-pci,drive=foreign,serial=not-ours",
             "-drive", f"file={EXTRA_BLANK},if=none,format=raw,id=xblank", "-device", "virtio-blk-pci,drive=xblank,serial=another-blank"]
    vm = DiskVM(extra=extra)
    try:
        vm.boot()
        st = vm.sh("cat /run/apps-disk.state; cat /run/apps-disk; grep -c . /proc/partitions; for b in /sys/block/vd*; do echo $b $(cat $b/serial); done")
        expect("mounted" in st.split("\n")[0], "apps disk state is not 'mounted': %r" % st)
        dev = st.split("\n")[1].strip()
        expect("%s mylinux-apps" % dev.replace("/dev/", "/sys/block/") in st, "mounted device %s is not the one with the mylinux-apps serial: %r" % (dev, st))
        expect(st.count("/sys/block/vd") == 3, "expected three virtio disks: %r" % st)
        m = vm.sh("cat /proc/mounts | grep -c ' /mnt/apps'; cat /mnt/apps/.mylinux/ready; apps-mounts check && echo check-ok; apps-run true && echo run-ok; cat /run/apps-disk.info")
        expect("check-ok" in m and "run-ok" in m, "chroot not usable: %r" % m)
        expect("legacy" in m or m.split("\n")[1].strip().isdigit(), "ready marker missing on the set-up disk: %r" % m)
        r = vm.sh("mount | grep -c '/mnt/apps'")
        expect(int(r.strip() or 0) >= 8, "expected the nested chroot mounts (dev, proc, sys, tmp, pts, shm, run, share), got %r" % r)
    finally:
        vm.stop(); time.sleep(1)
    expect(sha(FOREIGN) == f0, "the foreign disk was modified")
    expect(sha(EXTRA_BLANK) == b0, "the extra blank disk was modified")


def scenario_lock():
    vm = DiskVM()
    try:
        vm.boot()
        out = vm.sh("rm -f /run/apps-setup.status; setsid sh -c 'exec 9>/run/apps-setup.lock; flock 9; sleep 15' < /dev/null > /dev/null 2>&1 & sleep 1; apps-setup > /tmp/setup2.log 2>&1; echo rc=$?; cat /tmp/setup2.log", 6)
        expect("rc=3" in out and "already running" in out, "apps-setup did not respect the lock: %r" % out)
        vm.sh("sleep 15; setsid sh -c 'apps-setup > /tmp/setup1.log 2>&1' < /dev/null & echo bg", 18)
        deadline = time.time() + 900
        status = ""
        while time.time() < deadline:
            status = vm.sh("cat /run/apps-setup.status", 2)
            if "state=running" not in status: break
            time.sleep(10)
        expect("state=done" in status or "state=partial" in status, "apps-setup did not finish: %r\n%s" % (status, vm.sh("tail -30 /tmp/setup1.log", 3)))
        marks = vm.sh("ls /mnt/apps/.mylinux; cat /mnt/apps/.mylinux/ready")
        for s in ("stage-rootfs-done", "stage-desktop-done", "stage-devtools-done", "ready"):
            expect(s in marks, "marker %s missing after repair: %r" % (s, marks))
        if "state=partial" in status:
            print("    (agents stage partial: %s)" % status.strip().replace("\n", " | "))
        else:
            expect("stage-agents-done" in marks, "agents marker missing: %r" % marks)
            v = vm.sh("apps-run codex --version; apps-run test -x /root/.local/bin/claude && echo claude-ok")
            expect("codex" in v.lower() and "claude-ok" in v, "agents not runnable: %r" % v)
    finally:
        vm.stop(); time.sleep(1)


def scenario_shutdown():
    vm = DiskVM()
    try:
        vm.boot()
        vm.sh("cd /root; XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 setsid apps-run sleep 600 < /dev/null > /dev/null 2>&1 & sleep 1; echo started", 3)
        before = vm.sh("mount | grep -c '/mnt/apps\\| /root '")
        expect(int(before.strip() or 0) >= 9, "expected the chroot mounts before stop: %r" % before)
        out = vm.sh("/etc/init.d/S45apps stop; echo rc=$?; mount | grep -c '/mnt/apps\\| /root '; pgrep -f 'sleep 600' || echo no-chroot-processes", 12)
        expect("unmounted" in out, "S45apps stop did not report a clean unmount: %r" % out)
        expect("no-chroot-processes" in out, "the chroot process survived the stop: %r" % out)
        lines = [l for l in out.split("\n") if l.strip().isdigit()]
        expect(lines and lines[-1].strip() == "0", "mounts left after stop: %r" % out)
        again = vm.sh("/etc/init.d/S45apps start; sleep 2; cat /run/apps-disk.state; apps-run true && echo run-ok", 8)
        expect("mounted" in again and "run-ok" in again, "restart after stop failed: %r" % again)
    finally:
        vm.stop(); time.sleep(1)


def scenario_blank():
    """Wipes the throwaway test disk and share (tools/fresh-start.sh without `keep`), so the scenarios after it
    run on a disk set up by the current apps-setup."""
    fresh = os.path.join(OUT, "apps-fresh.img")
    if os.path.exists(fresh): os.remove(fresh)
    if os.path.exists(SHARE): subprocess.run(["rm", "-rf", SHARE])
    if os.path.exists(os.path.join(ROOT, "share", "myshell")): 
        os.makedirs(SHARE, exist_ok=True)
    vm = DiskVM()
    try:
        vm.boot()
        st = vm.sh("cat /run/apps-disk.state; cat /run/apps-disk; cat /run/tailscaled.state-dir; ls /mnt/apps 2>/dev/null | wc -l")
        expect(st.startswith("blank"), "new disk not reported blank: %r" % st)
        expect("/run/tailscale-state" in st, "tailscaled should use the volatile state dir before the disk exists: %r" % st)
        # first run, interrupted during the desktop stage
        vm.sh("setsid sh -c 'apps-setup > /tmp/setup1.log 2>&1' < /dev/null & echo bg", 2)
        deadline = time.time() + 600
        while time.time() < deadline:
            s = vm.sh("cat /run/apps-setup.status 2>/dev/null", 2)
            if "stage=desktop" in s and "state=running" in s: break
            if "state=failed" in s: raise Fail("setup failed before the desktop stage: %r\n%s" % (s, vm.sh("tail -20 /tmp/setup1.log")))
            time.sleep(5)
        else:
            raise Fail("never reached the desktop stage")
        time.sleep(8)
        out = vm.sh("pkill -TERM -f 'apps-setup' ; pkill -TERM apt-get; pkill -TERM dpkg; sleep 3; cat /run/apps-setup.status; ls /mnt/apps/.mylinux", 8)
        expect("state=failed" in out and "stage=desktop" in out, "interrupted run not reported as failed at the desktop stage: %r" % out)
        expect("stage-rootfs-done" in out and "stage-desktop-done" not in out, "stage markers wrong after interruption: %r" % out)
        expect("ready" not in out.split("state=")[0] and "\nready" not in out, "ready marker must not exist after an interrupted setup: %r" % out)
        # second run continues
        vm.sh("setsid sh -c 'apps-setup > /tmp/setup2.log 2>&1' < /dev/null & echo bg", 2)
        deadline = time.time() + 1500; s = ""
        while time.time() < deadline:
            s = vm.sh("cat /run/apps-setup.status 2>/dev/null", 2)
            if "state=running" not in s: break
            time.sleep(10)
        expect("state=done" in s or "state=partial" in s, "second run did not finish: %r\n%s" % (s, vm.sh("tail -30 /tmp/setup2.log")))
        fin = vm.sh("ls /mnt/apps/.mylinux; cat /mnt/apps/.mylinux/ready; cat /run/apps-disk.state; apps-run chromium --version 2>/dev/null | head -1; cat /run/tailscaled.state-dir; grep -c 'Downloading Debian' /tmp/setup2.log")
        for m in ("stage-rootfs-done", "stage-desktop-done", "stage-devtools-done", "ready", "mounted"):
            expect(m in fin, "%s missing after the second run: %r" % (m, fin))
        expect("Chromium" in fin, "Chromium not runnable: %r" % fin)
        expect("/root/.config/tailscale" in fin, "tailscaled not migrated to the disk: %r" % fin)
        expect(fin.strip().split("\n")[-1].strip() == "0", "the second run downloaded the rootfs again (stage marker ignored): %r" % fin)
        if "state=partial" in s: print("    (agents stage partial: %s)" % s.strip().replace("\n", " | "))
    finally:
        vm.stop(); time.sleep(1)


def scenario_reboot():
    """A file written to the home directory survives `reboot`; the disk comes back mounted and ready."""
    vm = DiskVM()
    try:
        vm.boot()
        stamp = "reboot-%d" % int(time.time())
        vm.sh("echo %s > /root/.vmtest-reboot; sync; echo ok" % stamp, 2)
        vm.serial("reboot", 1)
        time.sleep(12)
        deadline = time.time() + 120
        while time.time() < deadline:
            try:
                if os.path.exists(SERIAL) and "u\\p".replace("\\", "") in vm.serial("echo u\\p", 2): break
            except Exception:
                pass
            time.sleep(3)
        out = vm.sh("cat /run/apps-disk.state; cat /root/.vmtest-reboot; rm -f /root/.vmtest-reboot; test -f /mnt/apps/.mylinux/ready && echo ready-ok", 4)
        expect("mounted" in out and stamp in out and "ready-ok" in out, "after reboot: %r" % out)
    finally:
        vm.stop(); time.sleep(1)


SCENARIOS = [("blank", scenario_blank), ("states", scenario_states), ("lock", scenario_lock), ("shutdown", scenario_shutdown), ("reboot", scenario_reboot)]



def main(argv):
    names = [a for a in argv if not a.startswith("--")]
    results = []
    for name, fn in SCENARIOS:
        if names and name not in names: continue
        t0 = time.time()
        try:
            fn(); results.append((name, "PASS", "%.0fs" % (time.time() - t0)))
        except Fail as e:
            results.append((name, "FAIL", str(e)))
        except Exception as e:
            results.append((name, "ERROR", repr(e)))
        print("%-10s %s" % (name, results[-1][1]))
    print()
    for n, s, i in results: print("%-10s %-5s %s" % (n, s, i))
    return 1 if any(r[1] != "PASS" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
