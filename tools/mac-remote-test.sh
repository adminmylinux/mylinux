#!/bin/sh
# End-to-end test of the launcher's native remote access (docs/MAC-REMOTE-PLAN.md) against the myLinux test VM:
# boots the VM with its Xvnc and sshd ports forwarded to the Mac, opens a VNC window that types a stamp through the
# viewer's own key path (MYLINUX_TEST_TYPE), and an SSH window that logs in with a Keychain password and attaches a
# tmux session; both are checked on the guest. Uses a data folder of its own, never the user's remote machines.
# Needs: the debug launcher built (cd mac && swift build), Homebrew libvncserver, the test disk (tools/fresh-start.sh).
set -eu
cd "$(dirname "$0")/.."
S=$(mktemp -d "${TMPDIR:-/tmp}/mylinux-remote.XXXXXX"); trap 'rm -rf "$S"' EXIT
BIN=mac/.build/debug/myLinux
[ -x "$BIN" ] || { echo "build the launcher first: cd mac && swift build" >&2; exit 2; }
VNC=AAAAAAAA-0000-4000-8000-000000000001; SSH=AAAAAAAA-0000-4000-8000-000000000002
mkdir -p "$S/support"
cat > "$S/support/remote.json" <<EOF
[{"id":"$VNC","name":"test vnc","kind":"vnc","host":"127.0.0.1","port":15905,"username":"","quality":"balanced","keyboard":"optionSuper","hasPassword":false},
 {"id":"$SSH","name":"test ssh","kind":"ssh","host":"127.0.0.1","port":12222,"username":"root","tmux":"main","keyboard":"mac","hasPassword":true}]
EOF
fails=0
ok() { echo "  ok   $1"; }; ko() { echo "  FAIL $1"; fails=$((fails + 1)); }
pkill -f "$BIN" 2>/dev/null || true
security add-generic-password -U -s "myLinux Remote" -a "ssh:$SSH" -l "myLinux Remote: test ssh" -T /usr/bin/security -T "$PWD/$BIN" -w test
cleanup() { pkill -f "$BIN" 2>/dev/null || true; wait 2>/dev/null; security delete-generic-password -s "myLinux Remote" -a "ssh:$SSH" >/dev/null 2>&1 || true
            python3 -c "import sys; sys.path.insert(0,'tools/vmtest'); import vmtest as V; V.VM().stop()"; rm -rf "$S"; }
trap cleanup EXIT

echo "booting the test VM with forwarded ports ..."
python3 - <<'PY'
import sys, os, time, subprocess, shutil, re
sys.path.insert(0, "tools/vmtest"); import vmtest as V
vm = V.VM()
ini = os.path.join(V.SHARE, "mylinux.ini"); text = open(ini).read() if os.path.exists(ini) else ""
if "[test]" not in text: text += "\n[test]\ndiag=true\n"
open(ini, "w").write(text)
for p in (V.QMP, V.SERIAL):
    if os.path.exists(p): os.remove(p)
subprocess.run(["pkill", "-f", "apps-fresh.img"], capture_output=True); time.sleep(1)
env = dict(os.environ, SERIAL=f"unix:{V.SERIAL},server,nowait", RES="1688x1016", PLACER="0", FORWARD="15905:5905,12222:2222")
subprocess.Popen([os.path.join(V.ROOT, "tools", "fresh-start.sh"), "keep", "-qmp", f"unix:{V.QMP},server,nowait", "-display", "none"],
                 cwd=V.ROOT, env=env, stdout=open(os.path.join(V.OUT, "vmtest-boot.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
deadline = time.time() + 120
while time.time() < deadline:
    if os.path.exists(V.QMP) and os.path.exists(V.SERIAL) and vm.diag(timeout=5): break
    time.sleep(2)
else: sys.exit("the test VM did not come up")
time.sleep(4)
V.ensure_vnc_server(vm); V.ensure_sshd(vm)
vm.serial("apps-run tmux kill-server 2>/dev/null; apps-run pkill -f 'vnc-typed-mac' 2>/dev/null; : > /tmp/vnc-typed-mac; cd /root; setsid apps-run env DISPLAY=:5 xterm -geometry 110x37+0+0 -e sh -c 'cat > /tmp/vnc-typed-mac' > /dev/null 2>&1 < /dev/null & echo", 3)
PY

echo "VNC: a window that types through the viewer"
STAMP="mac-vnc-$$"
MYLINUX_SUPPORT_DIR="$S/support" MYLINUX_TEST_TYPE="echo $STAMP
" "$BIN" --remote "$VNC" > "$S/vnc.log" 2>&1 &
sleep 5
osascript -e 'tell application "System Events" to tell process "myLinux" to click button "Connect" of sheet 1 of window "test vnc"' >/dev/null 2>&1 || true
sleep 8
python3 - "$STAMP" <<'PY'
import sys, os, time
sys.path.insert(0, "tools/vmtest"); import vmtest as V
vm = V.VM(); out = os.path.join(V.SHARE, "vmtest", "vnc-typed-mac.txt")
if os.path.exists(out): os.remove(out)
vm.serial("cp /tmp/vnc-typed-mac /mnt/share/vmtest/vnc-typed-mac.txt; echo", 2); time.sleep(0.5)
got = open(out).read() if os.path.exists(out) else ""
sys.exit(0 if sys.argv[1] in got else 1)
PY
[ $? -eq 0 ] && ok "text typed in the VNC window reached the remote xterm" || ko "text typed in the VNC window did not reach the remote (see $S/vnc.log)"
grep -q "connected" "$S/vnc.log" && ok "connection state reported" || ko "no connected state in the log"
pkill -f "$BIN" 2>/dev/null || true; wait 2>/dev/null; sleep 1

echo "SSH: a window that logs in with the Keychain password and attaches tmux"
MYLINUX_SUPPORT_DIR="$S/support" "$BIN" --remote "$SSH" > "$S/ssh.log" 2>&1 &
sleep 12
python3 - <<'PY'
import sys
sys.path.insert(0, "tools/vmtest"); import vmtest as V
vm = V.VM()
out = vm.serial("apps-run tmux ls 2>&1; echo end", 3)
sys.exit(0 if "main:" in out and "(attached)" in out else 1)
PY
[ $? -eq 0 ] && ok "ssh logged in through the askpass helper and is attached to tmux \"main\"" || ko "no attached tmux session on the guest (see $S/ssh.log)"
if [ $fails -eq 0 ]; then echo "mac remote: all passed"; else echo "mac remote: $fails failed"; fi
exit $fails
