#!/bin/sh
# Boot the image on the Mac with QEMU + Apple Hypervisor.framework.
# Terminal = serial console (root shell). Window = the Qt app. Quit: Ctrl-A X in the terminal.
# Scripted use: SERIAL=unix:out/serial.sock,server,nowait ./run.sh -qmp unix:out/qmp.sock,server,nowait
# Guest resolution: RES=WxH ./run.sh   (default 1920x1200). The Mac window scales the guest to its
# size (zoom-to-fit), so drag the window corner or use View > Zoom To Fit / full screen in QEMU.
cd "$(dirname "$0")"
# Default guest resolution = the Mac screen in points minus window margins, so the desktop is shown 1:1
# (scaling the framebuffer blurs text). Override with RES=WxH.
if [ -z "$RES" ]; then
  SB=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null | tr -d ' ')
  SW=$(echo "$SB" | cut -d, -f3); SH=$(echo "$SB" | cut -d, -f4)
  if [ -n "$SW" ] && [ "$SW" -gt 800 ] 2>/dev/null; then
    RES="$(( (SW - 80) / 8 * 8 ))x$(( (SH - 80 - 25 - 28) / 8 * 8 ))"
  else
    RES=1600x1000
  fi
fi
XRES="${RES%x*}"; YRES="${RES#*x}"
# Optional Debian "apps disk" (tools/make-apps-disk.sh -> out/apps.img): apt + Chromium etc. live there.
APPS_IMG="${APPS_IMG:-out/apps.img}"
if [ ! -f "$APPS_IMG" ]; then   # blank sparse disk; the VM formats and populates it on first boot (apps-setup)
  python3 -c "open('$APPS_IMG','wb').truncate(${APPS_SIZE_GB:-16} * 2**30)" && echo "created blank apps disk $APPS_IMG (${APPS_SIZE_GB:-16} GB, sparse)"
fi
APPS="-drive file=$APPS_IMG,if=none,format=raw,id=apps -device virtio-blk-pci,drive=apps"
# Shared folder (settings file, dev binaries, host-cmd channel). SHARE_DIR=... to use another one.
SHARE_DIR="${SHARE_DIR:-share}"; mkdir -p "$SHARE_DIR"
# Host agent: the guest shell writes a command into $SHARE_DIR/host-cmd; we act on it here (window fit etc.).
rm -f "$SHARE_DIR/host-cmd"
( while sleep 0.5; do
    [ -f "$SHARE_DIR/host-cmd" ] || continue
    cmd=$(head -1 "$SHARE_DIR/host-cmd"); rm -f "$SHARE_DIR/host-cmd"
    case "$cmd" in fit|center|fullscreen|native) tools/host-window.sh "$cmd" >/dev/null 2>&1 & ;; esac
  done ) &
AGENT=$!
trap 'kill $AGENT 2>/dev/null' EXIT
# Keyboard (default GRAB=opt): Option and Cmd are swapped inside the guest, so the Option key is the
# Super/⌘ key of the desktop (Option+Space = launcher, Option+T = terminal, ...) and macOS keeps Cmd.
# GRAB=full instead captures every combo for the guest (real Cmd, needs Accessibility, Ctrl+Opt+G releases).
# GRAB=none forwards Cmd only where macOS does not claim it.
case "${GRAB:-opt}" in
  full) KEYS="full-grab=on" ;;
  none) KEYS="full-grab=off" ;;
  *)    KEYS="swap-opt-cmd=on" ;;
esac
# Launch through out/myLinux.app so macOS shows "myLinux" as app name, Dock icon and window title.
tools/make-app-bundle.sh >/dev/null   # (re)creates the bundle only when needed
out/myLinux.app/Contents/MacOS/myLinux -name myLinux \
  -M virt -accel hvf -cpu host -smp 4 -m "${MEM:-6G}" \
  -kernel out/Image -initrd out/rootfs.cpio.gz \
  -append "console=ttyAMA0 quiet loglevel=3 mylinux.res=$RES video=Virtual-1:${RES}@60" \
  -device virtio-gpu-pci,xres="$XRES",yres="$YRES" \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  $APPS \
  -display cocoa,show-cursor=on,zoom-to-fit=on,zoom-interpolation=on,left-command-key=on,"$KEYS" \
  -serial "${SERIAL:-mon:stdio}" \
  -virtfs local,path="$PWD/$SHARE_DIR",mount_tag=share,security_model=none,id=share \
  "$@"
