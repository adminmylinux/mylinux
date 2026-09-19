#!/bin/sh
# Boot the image on the Mac with QEMU + Apple Hypervisor.framework.
# Terminal = serial console (root shell). Window = the Qt app. Quit: Ctrl-A X in the terminal.
# Scripted use: SERIAL=unix:out/serial.sock,server,nowait ./run.sh -qmp unix:out/qmp.sock,server,nowait
# Environment: RES=WxH, MEM=6G, APPS_IMG=path, APPS_SIZE_GB=16, SHARE_DIR=path, NAME=window title,
#              GRAB=opt|full|none, MOUSE=tablet|relative, CLIPBOARD=0, DRYRUN=1 (print the QEMU command and exit),
#              PLACER=0 (do not move the window onto the current display; no Automation permission needed),
#              FORWARD=host:guest[,host:guest...] (TCP ports on 127.0.0.1 forwarded into the guest, for tests),
#              MYLINUX_QEMU=brew|runtime (default: the accelerated runtime in $MYLINUX_OUT/qemu-runtime when
#              tools/get-qemu-runtime.sh installed one, else Homebrew's QEMU),
#              MYLINUX_OUT=dir holding Image, rootfs.cpio.gz, the default apps.img and the myLinux.app wrapper
#              (default: out/ of the repository; the Mac launcher app points it at its Application Support folder).
# Works from any directory: paths are resolved against the repository, relative overrides against
# the caller's directory. Paths may contain spaces and quotes.
set -eu
REPO=$(cd "$(dirname "$0")" && pwd)
CALLER="$PWD"
cd "$REPO"
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CALLER" "$1" ;; esac; }
die() { echo "run.sh: $*" >&2; exit 1; }
OUT="${MYLINUX_OUT:+$(abs "$MYLINUX_OUT")}"; OUT="${OUT:-$REPO/out}"
export MYLINUX_OUT="$OUT"

# ---- guest resolution: the display under the mouse pointer, in points, minus window margins --------
# QEMU creates its (non-resizable) window at the guest size in device pixels and centres it; the app
# bundle is marked non-Retina so one guest pixel is one point. View > Zoom To Fit makes the window
# resizable again. If the window lands on another display, the placer below moves it (needs
# Accessibility for the terminal app; harmless without).
SCREEN=$(osascript -l JavaScript -e '
  ObjC.import("AppKit");
  const m = $.NSEvent.mouseLocation, all = $.NSScreen.screens, mainH = $.NSScreen.screens.objectAtIndex(0).frame.size.height;
  let s = $.NSScreen.mainScreen;
  for (let i = 0; i < all.count; i++) { const f = all.objectAtIndex(i).frame;
    if (m.x >= f.origin.x && m.x < f.origin.x + f.size.width && m.y >= f.origin.y && m.y < f.origin.y + f.size.height) s = all.objectAtIndex(i); }
  const v = s.visibleFrame;   // points, Cocoa coordinates (y up); System Events wants y down from the top of the main screen
  [Math.round(v.size.width), Math.round(v.size.height), Math.round(v.origin.x), Math.round(mainH - (v.origin.y + v.size.height))].join(" ")' 2>/dev/null || true)
SW=${SCREEN%% *}; REST=${SCREEN#* }; SH=${REST%% *}; REST=${REST#* }; SX=${REST%% *}; SY=${REST#* }
case "$SW" in ''|*[!0-9]*) SW=""; SH=""; SX=0; SY=0 ;; esac
if [ -z "${RES:-}" ]; then
  if [ -n "$SW" ] && [ "$SW" -gt 800 ]; then
    RES="$(( (SW - 40) / 8 * 8 ))x$(( (SH - 40 - 28) / 8 * 8 ))"     # 28 = title bar
  else
    RES=1600x1000
  fi
fi
case "$RES" in
  [0-9]*x[0-9]*) XRES="${RES%x*}"; YRES="${RES#*x}" ;;
  *) die "RES must look like 1920x1200 (got '$RES')" ;;
esac
[ "$XRES" -ge 640 ] && [ "$XRES" -le 8192 ] && [ "$YRES" -ge 480 ] && [ "$YRES" -le 8192 ] || die "RES out of range: $RES"

# ---- disks and share ------------------------------------------------------------------------------
[ -s "$OUT/Image" ] && [ -s "$OUT/rootfs.cpio.gz" ] || die "$OUT/Image and $OUT/rootfs.cpio.gz are missing: run tools/get-image.sh or ./build.sh"
APPS_IMG=$(abs "${APPS_IMG:-$OUT/apps.img}")
APPS_SIZE_GB="${APPS_SIZE_GB:-16}"
case "$APPS_SIZE_GB" in ''|*[!0-9]*) die "APPS_SIZE_GB must be a whole number of GB" ;; esac
[ "$APPS_SIZE_GB" -ge 4 ] && [ "$APPS_SIZE_GB" -le 2000 ] || die "APPS_SIZE_GB out of range: $APPS_SIZE_GB"
if [ ! -f "$APPS_IMG" ]; then   # blank sparse disk; the VM formats and populates it on first boot (apps-setup)
  python3 -c 'import sys; open(sys.argv[1], "wb").truncate(int(sys.argv[2]) * 2**30)' "$APPS_IMG" "$APPS_SIZE_GB" \
    && echo "created blank apps disk $APPS_IMG ($APPS_SIZE_GB GB, sparse)"
fi
SHARE_DIR=$(abs "${SHARE_DIR:-share}"); mkdir -p "$SHARE_DIR"
NAME="${NAME:-myLinux}"
MEM="${MEM:-6G}"
# Keyboard (default GRAB=opt): Option and Cmd are swapped inside the guest, so the Option key is the
# Super/⌘ key of the desktop (Option+Space = launcher, Option+T = terminal, ...) and macOS keeps Cmd.
# GRAB=full instead captures every combo for the guest (real Cmd, needs Accessibility, Ctrl+Opt+G releases).
# GRAB=none forwards Cmd only where macOS does not claim it.
case "${GRAB:-opt}" in
  full) KEYS="full-grab=on" ;;
  none) KEYS="full-grab=off" ;;
  opt)  KEYS="swap-opt-cmd=on" ;;
  *) die "GRAB must be opt, full or none" ;;
esac

# Pointer (default MOUSE=tablet): an absolute tablet, so the guest cursor sits exactly under the Mac pointer and
# the mouse slides in and out of the window freely. MOUSE=relative is a plain mouse: a click in the window
# captures the pointer (hidden and confined by QEMU, every movement goes to the guest) until Ctrl+Option+G.
case "${MOUSE:-tablet}" in
  tablet)   POINTER=virtio-tablet-pci ;;
  relative) POINTER=virtio-mouse-pci ;;
  *) die "MOUSE must be tablet or relative" ;;
esac

# Port forwards for tests: FORWARD=15905:5905,12222:2222 reaches the guest's Xvnc and sshd from the Mac.
NETDEV="user,id=n0"
for fw in $(printf '%s' "${FORWARD:-}" | tr ',' ' '); do
  case "$fw" in [0-9]*:[0-9]*) NETDEV="$NETDEV,hostfwd=tcp:127.0.0.1:${fw%%:*}-:${fw##*:}" ;; *) die "FORWARD entries look like hostport:guestport (got '$fw')" ;; esac
done

# ---- which QEMU: the accelerated runtime in $OUT/qemu-runtime when installed, else Homebrew's -------
# The runtime (tools/get-qemu-runtime.sh) is QEMU with VirGL: the guest's OpenGL runs on the Mac's GPU through
# virtio-gpu-gl -> virglrenderer -> ANGLE -> Metal, given a guest Mesa with the virgl driver (one without keeps
# rendering in software on the same device). It carries no ROM or data files, hence romfile= on every PCI device,
# and under HVF it has the in-kernel GICv3 only. MYLINUX_QEMU=brew|runtime overrides the choice.
FLAVOUR=$(sh tools/qemu-flavour.sh "$OUT") || die "no usable QEMU"
if [ "$FLAVOUR" = runtime ]; then
  MACHINE="virt,gic-version=3"; ROM=",romfile="; GPU="virtio-gpu-gl-pci,max_outputs=1"; GL=",gl=es"
else
  MACHINE="virt"; ROM=""; GPU="virtio-gpu-pci"; GL=""
fi

# ---- the QEMU command, built as a proper argument list (no word splitting of paths) ---------------
QEMU="$OUT/myLinux.app/Contents/MacOS/qemu-myLinux"
set -- \
  -name "$NAME" -M "$MACHINE" -accel hvf -cpu host -smp 4 -m "$MEM" \
  -kernel "$OUT/Image" -initrd "$OUT/rootfs.cpio.gz" \
  -append "console=ttyAMA0 quiet loglevel=3 mylinux.res=$RES video=Virtual-1:${RES}@60" \
  -device "$GPU,xres=$XRES,yres=$YRES$ROM" \
  -device "virtio-keyboard-pci$ROM" -device "$POINTER$ROM" \
  -netdev "$NETDEV" -device "virtio-net-pci,netdev=n0$ROM" \
  -drive "file=$APPS_IMG,if=none,format=raw,id=apps" -device "virtio-blk-pci,drive=apps,serial=mylinux-apps$ROM" \
  -display "cocoa$GL,show-cursor=on,zoom-to-fit=off,zoom-interpolation=on,left-command-key=on,$KEYS" \
  -serial "${SERIAL:-mon:stdio}" \
  -virtfs "local,path=$SHARE_DIR,mount_tag=share,security_model=none,id=share" \
  "$@"
if [ "${DRYRUN:-0}" = 1 ]; then
  echo "RES=$RES APPS_IMG=$APPS_IMG SHARE_DIR=$SHARE_DIR NAME=$NAME QEMU=$FLAVOUR"
  for a in "$@"; do printf '%s\n' "$a"; done
  exit 0
fi
# Launch through $OUT/myLinux.app so macOS shows "myLinux" as app name, Dock icon and window title.
tools/make-app-bundle.sh >/dev/null || die "could not prepare $OUT/myLinux.app"
[ -x "$QEMU" ] || die "$QEMU is missing"

# ---- host agent: window commands from the guest + text clipboard bridge -----------------------------
# The guest shell writes a command into $SHARE_DIR/host-cmd (allowlisted below, never executed as
# shell); the clipboard bridge mirrors the Mac clipboard into $SHARE_DIR/clipboard/mac.txt and copies
# guest.txt (from clipboard-bridge in the guest) into the Mac clipboard. CLIPBOARD=0 turns that off.
# Everything is scoped to this instance: its own share directory and its window title ($NAME).
printf '%s\n' "$NAME" > "$SHARE_DIR/instance"
rm -f "$SHARE_DIR/host-cmd"; mkdir -p "$SHARE_DIR/clipboard"; rm -f "$SHARE_DIR/clipboard"/*.txt "$SHARE_DIR/clipboard"/*.seq "$SHARE_DIR/clipboard"/*.last
CLIPBOARD="${CLIPBOARD:-1}"
( while sleep 0.5; do
    if [ -f "$SHARE_DIR/host-cmd" ]; then
      cmd=$(head -1 "$SHARE_DIR/host-cmd"); rm -f "$SHARE_DIR/host-cmd"
      case "$cmd" in fit|center|fullscreen|native) tools/host-window.sh "$cmd" "$NAME" >/dev/null 2>&1 & ;; esac
    fi
  done ) &
AGENT=$!
CLIP=""
if [ "$CLIPBOARD" = 1 ]; then tools/clipboard-host.sh "$SHARE_DIR/clipboard" & CLIP=$!; fi
# Window placer: QEMU centres its window on whichever display macOS chose (and again when the guest
# sets its mode), so once the window has the guest's width, move it onto the display RES was computed
# for and keep it there until the position has held for a few checks. The window is found by its title:
# System Events mixes up two processes of the same app bundle, so a pid is not a safe handle.
# PLACER=0 skips it: driving System Events makes macOS ask the calling app for Automation permission,
# which the Mac launcher app does not ask for unless the user turns it on.
( [ -n "$SW" ] && [ "${PLACER:-1}" = 1 ] || exit 0
  HELD=0
  for i in $(seq 1 120); do
    sleep 0.5
    R=$(osascript - "$NAME" "$XRES" "$SW" "$SH" "$SX" "$SY" 2>/dev/null <<'AS'
on run argv
  set {nm, w, sw, sh, sx, sy} to {item 1 of argv, item 2 of argv as integer, item 3 of argv as integer, item 4 of argv as integer, item 5 of argv as integer, item 6 of argv as integer}
  tell application "System Events"
    repeat with pr in (every process whose bundle identifier is "dev.mylinux.vm")
      repeat with win in windows of pr
        set t to name of win
        if t is nm or t starts with (nm & " - (Press") then
          set {cw, ch} to size of win
          if cw < (w * 9) div 10 then return "small"        -- guest mode not applied yet
          set tx to sx + (sw - cw) div 2
          set ty to sy + (sh - ch) div 2
          set {px, py} to position of win
          if (px - tx) * (px - tx) < 1600 and (py - ty) * (py - ty) < 1600 then return "held"   -- macOS may nudge it a little
          set position of win to {tx, ty}
          return "moved"
        end if
      end repeat
    end repeat
    return "no window"
  end tell
end run
AS
) || true
    case "$R" in held) HELD=$((HELD + 1)); [ $HELD -ge 4 ] && break ;; *) HELD=0 ;; esac
  done ) &
PLACER=$!
cleanup() { kill "$AGENT" "$PLACER" $CLIP 2>/dev/null; rm -f "$SHARE_DIR/host-cmd" "$SHARE_DIR/instance" "$SHARE_DIR/clipboard"/*.txt "$SHARE_DIR/clipboard"/*.seq "$SHARE_DIR/clipboard"/*.last; }

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
# A caller that goes away (the Mac launcher app quitting, a closed terminal) must not leave the helper loops
# behind: without this, SIGPIPE on the next log write kills the shell before the EXIT trap can run.
trap 'cleanup; exit 141' PIPE HUP

"$QEMU" "$@"
