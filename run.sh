#!/bin/sh
# Boot the image on the Mac with QEMU + Apple Hypervisor.framework.
# Terminal = serial console (root shell). Window = the Qt app. Quit: Ctrl-A X in the terminal.
# Scripted use: SERIAL=unix:out/serial.sock,server,nowait ./run.sh -qmp unix:out/qmp.sock,server,nowait
# Environment: RES=WxH, MEM=6G, APPS_IMG=path, APPS_SIZE_GB=16, SHARE_DIR=path, NAME=window title,
#              GRAB=opt|full|none, CLIPBOARD=0, DRYRUN=1 (print the QEMU command and exit).
# Works from any directory: paths are resolved against the repository, relative overrides against
# the caller's directory. Paths may contain spaces and quotes.
set -eu
REPO=$(cd "$(dirname "$0")" && pwd)
CALLER="$PWD"
cd "$REPO"
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CALLER" "$1" ;; esac; }
die() { echo "run.sh: $*" >&2; exit 1; }

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
[ -s out/Image ] && [ -s out/rootfs.cpio.gz ] || die "out/Image and out/rootfs.cpio.gz are missing: run tools/get-image.sh or ./build.sh"
APPS_IMG=$(abs "${APPS_IMG:-out/apps.img}")
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

# ---- the QEMU command, built as a proper argument list (no word splitting of paths) ---------------
QEMU=out/myLinux.app/Contents/MacOS/myLinux
set -- \
  -name "$NAME" -M virt -accel hvf -cpu host -smp 4 -m "$MEM" \
  -kernel out/Image -initrd out/rootfs.cpio.gz \
  -append "console=ttyAMA0 quiet loglevel=3 mylinux.res=$RES video=Virtual-1:${RES}@60" \
  -device "virtio-gpu-pci,xres=$XRES,yres=$YRES" \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -drive "file=$APPS_IMG,if=none,format=raw,id=apps" -device "virtio-blk-pci,drive=apps,serial=mylinux-apps" \
  -display "cocoa,show-cursor=on,zoom-to-fit=off,zoom-interpolation=on,left-command-key=on,$KEYS" \
  -serial "${SERIAL:-mon:stdio}" \
  -virtfs "local,path=$SHARE_DIR,mount_tag=share,security_model=none,id=share" \
  "$@"
if [ "${DRYRUN:-0}" = 1 ]; then
  echo "RES=$RES APPS_IMG=$APPS_IMG SHARE_DIR=$SHARE_DIR NAME=$NAME"
  for a in "$@"; do printf '%s\n' "$a"; done
  exit 0
fi
# Launch through out/myLinux.app so macOS shows "myLinux" as app name, Dock icon and window title.
tools/make-app-bundle.sh >/dev/null || die "could not prepare out/myLinux.app"
[ -x "$QEMU" ] || die "$QEMU is missing"

# ---- host agent: window commands from the guest + text clipboard bridge -----------------------------
# The guest shell writes a command into $SHARE_DIR/host-cmd (allowlisted below, never executed as
# shell); the clipboard bridge mirrors the Mac clipboard into $SHARE_DIR/clipboard/mac.txt and copies
# guest.txt (from clipboard-bridge in the guest) into the Mac clipboard. CLIPBOARD=0 turns that off.
# Everything is scoped to this instance: its own share directory and its window title ($NAME).
printf '%s\n' "$NAME" > "$SHARE_DIR/instance"
rm -f "$SHARE_DIR/host-cmd"; mkdir -p "$SHARE_DIR/clipboard"; rm -f "$SHARE_DIR/clipboard"/*.txt
CLIPBOARD="${CLIPBOARD:-1}"
( export LC_ALL=en_US.UTF-8; LAST_MAC=""; LAST_GUEST_M=""; G="$SHARE_DIR/clipboard/guest.txt"; M="$SHARE_DIR/clipboard/mac.txt"
  while sleep 0.5; do
    if [ -f "$SHARE_DIR/host-cmd" ]; then
      cmd=$(head -1 "$SHARE_DIR/host-cmd"); rm -f "$SHARE_DIR/host-cmd"
      case "$cmd" in fit|center|fullscreen|native) tools/host-window.sh "$cmd" "$NAME" >/dev/null 2>&1 & ;; esac
    fi
    [ "$CLIPBOARD" = 1 ] || continue
    if [ -f "$G" ]; then
      GM=$(stat -f %m "$G" 2>/dev/null || true)
      if [ "$GM" != "$LAST_GUEST_M" ]; then LAST_GUEST_M=$GM; T=$(cat "$G"); if [ -n "$T" ] && [ "$T" != "$LAST_MAC" ]; then printf '%s' "$T" | pbcopy; LAST_MAC=$T; fi; fi
    fi
    T=$(pbpaste 2>/dev/null || true)
    if [ -n "$T" ] && [ "$T" != "$LAST_MAC" ]; then LAST_MAC=$T; printf '%s' "$T" > "$M.tmp" && mv -f "$M.tmp" "$M"; fi
  done ) &
AGENT=$!
# Window placer: QEMU centres its window on whichever display macOS chose (and again when the guest
# sets its mode), so once the window has the guest's width, move it onto the display RES was computed
# for and keep it there until the position has held for a few checks. The window is found by its title:
# System Events mixes up two processes of the same app bundle, so a pid is not a safe handle.
( [ -n "$SW" ] || exit 0
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
cleanup() { kill "$AGENT" "$PLACER" 2>/dev/null; rm -f "$SHARE_DIR/host-cmd" "$SHARE_DIR/instance" "$SHARE_DIR/clipboard"/*.txt; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

"$QEMU" "$@"
