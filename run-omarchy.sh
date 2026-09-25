#!/bin/sh
# Boot an Omarchy machine on the Mac: the Try Omarchy guest (tools/get-omarchy.sh) on the accelerated QEMU runtime
# (tools/get-qemu-runtime.sh), Hyprland drawn by the Mac's GPU. The counterpart of run.sh for the second machine kind.
# A machine is a folder: its root disk (a raw ext4 image unpacked from the downloaded factory disk on first start,
# grown to DISK_SIZE_GB; the guest enlarges its filesystem on boot) and boot/, the kernel and initramfs that disk
# was created with (they must match the modules on the disk, so a newer download never replaces them).
# Environment: RES=WxH window size in points (default: fits the display the window opens on, the frontmost app's; a
#              Retina display gives the guest twice that in pixels, SCALE=1|2 overrides), DISK=path of the root disk (default $MYLINUX_OUT/omarchy-machine/omarchy.ext4), DISK_SIZE_GB=32,
#              NAME=window title, MEM=8G, CPUS=6, SHARE_DIR=folder shown inside Omarchy as ~/<its name> (optional),
#              GRAB=opt|full|none (as run.sh: Option acts as Super / every key to the guest / neither),
#              AUDIO=0 leaves the sound device out, CLIPBOARD=0 no clipboard sharing (default: text and PNG both ways
#              through tools/omarchy-clipboard.py, started beside QEMU),
#              SERIAL=chardev for the guest console (default: file <machine>/console.log),
#              QMP=unix socket path for control (a clean stop is {"execute":"system_powerdown"} there),
#              FORWARD=host:guest[,...] TCP ports on 127.0.0.1 (FORWARD=2223:22 plus SSH=1 reaches the guest's sshd),
#              DRYRUN=1 prints the QEMU command, MYLINUX_OUT=dir with omarchy/, qemu-runtime/ and the app wrapper.
set -eu
REPO=$(cd "$(dirname "$0")" && pwd)
CALLER="$PWD"
cd "$REPO"
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CALLER" "$1" ;; esac; }
die() { echo "run-omarchy.sh: $*" >&2; exit 1; }
# python3 is optional on a Mac: without Xcode's command line tools /usr/bin/python3 is a stub that fails and asks
# to install them, so it is only called when a real one is there
have_python() {
  [ -x /opt/homebrew/bin/python3 ] || [ -x /usr/local/bin/python3 ] && return 0
  dev=$(xcode-select -p 2>/dev/null) || return 1
  # with Xcode, /usr/bin/python3 goes through xcrun, which refuses to run anything until the Xcode licence is accepted
  case "$dev" in */CommandLineTools) [ -x "$dev/usr/bin/python3" ] ;; *) xcodebuild -license check >/dev/null 2>&1 ;; esac
}
# grow_file <path> <GB>: create the file or grow it to that size, sparse; never shrinks, keeps what is in it
grow_file() {
  want=$(( $2 * 1024 * 1024 * 1024 )); have=$(stat -f %z "$1" 2>/dev/null || echo 0)
  [ "$have" -ge "$want" ] || dd if=/dev/zero of="$1" bs=1 count=0 seek="$want" 2>/dev/null
}
OUT="${MYLINUX_OUT:+$(abs "$MYLINUX_OUT")}"; OUT="${OUT:-$REPO/out}"
export MYLINUX_OUT="$OUT"
G="$OUT/omarchy"

[ "$(MYLINUX_QEMU=auto sh tools/qemu-flavour.sh "$OUT")" = runtime ] || die "Omarchy needs the accelerated QEMU runtime: run tools/get-qemu-runtime.sh"
export MYLINUX_QEMU=runtime
# ---- window size and guest resolution -----------------------------------------------------------------------
# RES is the window's size in points (default: the display where the window will open, minus margins: Cocoa puts a
# new app's window on the display of the frontmost app's window, the launcher's or the terminal's). That display's
# backing scale decides the guest's pixels:
# the display maps guest pixels onto backing pixels, so on a Retina display (two per point) the guest gets twice RES
# and Hyprland scales by two: a sharp picture in a window of the size that was asked for. SCALE=1|2 overrides.
# The window starts fixed (zoom-to-fit=off) at exactly the guest's size, because the display code scales a text
# console wrongly whenever window and guest mode differ, which would garble Omarchy's first-boot setup screen; the
# launcher's menu bar item turns Zoom To Fit on and resizes it later, and the guest then follows the window.
SCREEN=$(osascript -l JavaScript -e '
  ObjC.import("AppKit"); ObjC.import("CoreGraphics");
  // the display of the frontmost app'"'"'s front window (the launcher, or the terminal this runs from): where Cocoa
  // opens a new app'"'"'s window; the primary display when that cannot be told
  const all = $.NSScreen.screens; let s = all.objectAtIndex(0);
  try {
    const pid = $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    const wins = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    const w = wins.filter(x => x.kCGWindowOwnerPID == pid && x.kCGWindowLayer == 0 && x.kCGWindowBounds.Height > 100)[0];
    if (w) {
      const mainH = all.objectAtIndex(0).frame.size.height;
      const cx = w.kCGWindowBounds.X + w.kCGWindowBounds.Width / 2, cy = mainH - (w.kCGWindowBounds.Y + w.kCGWindowBounds.Height / 2);
      for (let i = 0; i < all.count; i++) { const f = all.objectAtIndex(i).frame;
        if (cx >= f.origin.x && cx < f.origin.x + f.size.width && cy >= f.origin.y && cy < f.origin.y + f.size.height) s = all.objectAtIndex(i); }
    }
  } catch (e) {}
  const v = s.visibleFrame;
  [Math.round(v.size.width), Math.round(v.size.height), Math.round(s.backingScaleFactor)].join(" ")' 2>/dev/null || true)
SW=${SCREEN%% *}; REST=${SCREEN#* }; SH=${REST%% *}; DETECTED=${REST#* }
case "$SW$SH$DETECTED" in ''|*[!0-9]*) SW=""; SH=""; DETECTED=1 ;; esac
SCALE="${SCALE:-$DETECTED}"
case "$SCALE" in 1|2) ;; *) die "SCALE must be 1 or 2" ;; esac
# the title bar carries a toolbar (the Session menu and the size buttons): 52 points, not a plain title bar's 28
TITLE=52
if [ -z "${RES:-}" ]; then
  if [ -n "$SW" ] && [ "$SW" -gt 800 ]; then RES="$(( (SW - 40) / 8 * 8 ))x$(( (SH - 40 - TITLE) / 8 * 8 ))"; else RES=1600x1000; fi
fi
case "$RES" in [0-9]*x[0-9]*) XRES="${RES%x*}"; YRES="${RES#*x}" ;; *) die "RES must look like 1920x1200 (got '$RES')" ;; esac
[ "$XRES" -ge 640 ] && [ "$XRES" -le 8192 ] && [ "$YRES" -ge 480 ] && [ "$YRES" -le 8192 ] || die "RES out of range: $RES"
# a chosen size larger than the display would put the window's bottom off screen: keep it inside
if [ -n "$SW" ] && [ "$SW" -gt 800 ]; then
  MAXW=$(( (SW - 16) / 8 * 8 )); MAXH=$(( (SH - 16 - TITLE) / 8 * 8 ))
  [ "$XRES" -le "$MAXW" ] || XRES=$MAXW; [ "$YRES" -le "$MAXH" ] || YRES=$MAXH
  [ "$RES" = "${XRES}x${YRES}" ] || { echo "run-omarchy.sh: $RES does not fit the display, using ${XRES}x${YRES}" >&2; RES="${XRES}x${YRES}"; }
fi
GX=$(( XRES * SCALE )); GY=$(( YRES * SCALE ))
[ "$GX" -le 8192 ] && [ "$GY" -le 8192 ] || die "RES $RES is too large for a Retina display (the guest would need ${GX}x${GY})"

NAME="${NAME:-Omarchy}"
MEM="${MEM:-8G}"
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
CPUS="${CPUS:-$(( NCPU > 8 ? 6 : (NCPU > 4 ? 4 : 2) ))}"
case "$CPUS" in ''|*[!0-9]*) die "CPUS must be a number" ;; esac
[ "$CPUS" -ge 1 ] && [ "$CPUS" -le "$NCPU" ] || die "CPUS out of range: $CPUS (this Mac has $NCPU)"
DISK=$(abs "${DISK:-$OUT/omarchy-machine/omarchy.ext4}")
MACHINE=$(dirname "$DISK")
DISK_SIZE_GB="${DISK_SIZE_GB:-32}"
case "$DISK_SIZE_GB" in ''|*[!0-9]*) die "DISK_SIZE_GB must be a whole number of GB" ;; esac
[ "$DISK_SIZE_GB" -ge 8 ] && [ "$DISK_SIZE_GB" -le 2000 ] || die "DISK_SIZE_GB out of range: $DISK_SIZE_GB (8-2000)"
case "${GRAB:-opt}" in
  full) KEYS="full-grab=on" ;;
  none) KEYS="full-grab=off" ;;
  opt)  KEYS="swap-opt-cmd=on" ;;
  *) die "GRAB must be opt, full or none" ;;
esac
case "${AUDIO:-1}" in 0|1) ;; *) die "AUDIO must be 0 or 1" ;; esac
case "${CLIPBOARD:-1}" in 0|1) ;; *) die "CLIPBOARD must be 0 or 1" ;; esac
CLIPSOCK="/tmp/mylinux-$(id -u)-clip-$$.sock"      # short: unix socket paths are limited to 104 bytes
NETDEV="user,id=n0"
for fw in $(printf '%s' "${FORWARD:-}" | tr ',' ' '); do
  case "$fw" in [0-9]*:[0-9]*) NETDEV="$NETDEV,hostfwd=tcp:127.0.0.1:${fw%%:*}-:${fw##*:}" ;; *) die "FORWARD entries look like hostport:guestport (got '$fw')" ;; esac
done
APPEND="root=/dev/vda rw rootwait console=tty0 console=hvc0 loglevel=4 systemd.show_status=false rd.systemd.show_status=false mitigations=off nowatchdog omarchy.qemu_virgl=1"
[ "${SSH:-0}" = 1 ] && APPEND="$APPEND tryomarchy.ssh_access=1"

# ---- the shared folder: shown in Omarchy as ~/<its name>; the runtime's 9p reports the Mac user's files as uid 1000
SHARE_DIR="${SHARE_DIR:+$(abs "$SHARE_DIR")}"
if [ -n "$SHARE_DIR" ]; then
  mkdir -p "$SHARE_DIR"; SHARE_DIR=$(cd "$SHARE_DIR" && pwd -P)
  case "$SHARE_DIR" in *,*) die "the share folder's path must not contain a comma: $SHARE_DIR" ;; esac
  # never a system folder, the whole home folder or the user's Library; the launcher's own machine folders live in
  # ~/Library/Application Support/myLinux/machines and are the one exception
  case "$SHARE_DIR" in
    "$HOME/Library/Application Support/myLinux/machines"/?*) ;;
    /|/Users|/private|/tmp|/private/tmp|/System|/Library|/Applications|/Volumes|"$HOME"|"$HOME/Library"|"$HOME/Library"/*) die "refusing to share $SHARE_DIR (a system folder, the home folder or the Library)" ;;
  esac
  SHARE_NAME=$(printf '%s' "$(basename "$SHARE_DIR")" | base64 | tr '+/' '-_' | tr -d '=\n')
  APPEND="$APPEND omarchy.shared_folder_name=$SHARE_NAME"
  # tools for inside Omarchy travel in the share, in a folder named so it cannot collide with what is shared:
  # session save/restore (sh ~/<share>/mylinux-tools/install-session.sh once)
  if [ "${DRYRUN:-0}" != 1 ]; then mkdir -p "$SHARE_DIR/mylinux-tools/control" && cp -f omarchy/session/* "$SHARE_DIR/mylinux-tools/" 2>/dev/null || true; fi
  # the Session menu in the window's title bar: QEMU runs this to drop commands for the agent, and reads the status
  # the window runs the helper directly with these as its first argument (no shell: paths with spaces or quotes are fine)
  export MYLINUX_SESSION_CMD="$REPO/tools/omarchy-session-mac.sh" MYLINUX_SESSION_SHARE="$SHARE_DIR" MYLINUX_SESSION_STATUS="$SHARE_DIR/mylinux-tools/control/status.json"
fi
export MYLINUX_SIZE_BUTTONS=1     # the window's size and full screen buttons are for Omarchy (the guest follows the window)

# ---- first start of this machine: unpack the factory disk, grow it, keep the matching kernel beside it ----------
if [ "${DRYRUN:-0}" != 1 ] && { [ ! -f "$DISK" ] || [ ! -s "$MACHINE/boot/vmlinuz-linux" ] || [ ! -s "$MACHINE/boot/initramfs-linux.img" ]; }; then
  [ -s "$G/rootfs.ext4.zst" ] && [ -s "$G/vmlinuz-linux" ] && [ -s "$G/initramfs-linux.img" ] || die "the Omarchy guest is not downloaded: run tools/get-omarchy.sh"
  [ ! -f "$DISK" ] || die "$DISK exists but $MACHINE/boot (its kernel and initramfs) is missing; restore it or move the disk away"
  mkdir -p "$MACHINE/boot"
  echo "creating $DISK ($DISK_SIZE_GB GB, sparse) from Omarchy $(cat "$G/OMARCHY-REVISION" 2>/dev/null) ..."
  "$OUT/qemu-runtime/bin/zstd" -d -q -f --sparse -o "$DISK.new" "$G/rootfs.ext4.zst" || { rm -f "$DISK.new"; die "could not unpack the root disk"; }
  grow_file "$DISK.new" "$DISK_SIZE_GB" || { rm -f "$DISK.new"; die "could not grow the root disk"; }
  # the session tool goes into the disk now (system-wide, enabled), so the Session menu works from the first login
  tools/omarchy-bake-session.sh "$DISK.new" omarchy/session || echo "run-omarchy.sh: the session tool is not in the disk; inside Omarchy, sh ~/<share>/mylinux-tools/install-session.sh installs it" >&2
  cp "$G/vmlinuz-linux" "$G/initramfs-linux.img" "$MACHINE/boot/"; cp "$G/OMARCHY-REVISION" "$MACHINE/boot/OMARCHY-REVISION" 2>/dev/null || true
  mv "$DISK.new" "$DISK"
fi
SERIAL="${SERIAL:-file:$MACHINE/console.log}"
case "$SERIAL" in
  file:*) CONSOLE="file,id=hvc0,path=${SERIAL#file:}" ;;
  unix:*) CONSOLE="socket,id=hvc0,path=${SERIAL#unix:}"; CONSOLE=$(printf '%s' "$CONSOLE" | sed 's/,server,nowait$/,server=on,wait=off/') ;;
  *) die "SERIAL must be file:<path> or unix:<path>,server,nowait" ;;
esac

QEMU="$OUT/myLinux-omarchy.app/Contents/MacOS/qemu-myLinux"
set -- \
  -name "$NAME" -M virt,gic-version=3 -accel hvf -cpu host,pmu=off -smp "$CPUS" -m "$MEM" \
  -kernel "$MACHINE/boot/vmlinuz-linux" -initrd "$MACHINE/boot/initramfs-linux.img" -append "$APPEND" \
  -drive "if=none,id=root,file=$DISK,format=raw,media=disk,cache=writeback" -device "virtio-blk-pci,drive=root,serial=omarchy-root,romfile=" \
  -device "virtio-gpu-gl-pci,max_outputs=1,xres=$GX,yres=$GY,romfile=" \
  -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
  -netdev "$NETDEV" -device virtio-net-pci,netdev=n0,romfile= \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0,romfile= \
  -device virtio-balloon-pci,romfile= \
  -device virtio-serial-pci,id=ser,romfile= -chardev "$CONSOLE" -device virtconsole,bus=ser.0,nr=0,chardev=hvc0 \
  -display "cocoa,gl=es,show-cursor=on,zoom-to-fit=off,$KEYS" \
  "$@"
if [ "${CLIPBOARD:-1}" = 1 ]; then
  # the port Omarchy's own clipboard agent waits for; the Mac side is tools/omarchy-clipboard.py
  set -- "$@" -chardev "socket,id=clip,path=$CLIPSOCK,server=on,wait=off" \
    -device "virtserialport,bus=ser.0,nr=1,chardev=clip,name=dev.tryomarchy.clipboard"
fi
if [ "${AUDIO:-1}" = 1 ]; then
  set -- "$@" -audiodev sdl,id=audio -device intel-hda,id=hda,romfile= -device hda-micro,bus=hda.0,audiodev=audio
fi
if [ -n "$SHARE_DIR" ]; then
  set -- "$@" -fsdev "local,id=share,path=$SHARE_DIR,security_model=none,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000" \
    -device "virtio-9p-pci,fsdev=share,mount_tag=mac,romfile="
fi
[ -z "${QMP:-}" ] || set -- "$@" -qmp "unix:$QMP,server=on,wait=off"
if [ "${DRYRUN:-0}" = 1 ]; then
  echo "RES=$RES SCALE=$SCALE DISK=$DISK SHARE_DIR=$SHARE_DIR NAME=$NAME CPUS=$CPUS MEM=$MEM"
  echo "SESSION_CMD=${MYLINUX_SESSION_CMD:-} SESSION_SHARE=${MYLINUX_SESSION_SHARE:-}"
  for a in "$@"; do printf '%s\n' "$a"; done
  exit 0
fi
MYLINUX_BUNDLE=omarchy tools/make-app-bundle.sh >/dev/null || die "could not prepare $OUT/myLinux-omarchy.app"
[ -x "$QEMU" ] || die "$QEMU is missing"
# the clipboard bridge connects once QEMU has made the socket and leaves when QEMU (its parent after the exec) is gone
# the bridge is the launcher's own binary (MYLINUX_HELPER, set by the app); from the command line, the Python one
if [ "${CLIPBOARD:-1}" = 1 ]; then
  rm -f "$CLIPSOCK"
  if [ -n "${MYLINUX_HELPER:-}" ] && [ -x "$MYLINUX_HELPER" ]; then "$MYLINUX_HELPER" --omarchy-clipboard "$CLIPSOCK" 2>>"${MACHINE}/clipboard.log" &
  elif have_python; then python3 tools/omarchy-clipboard.py "$CLIPSOCK" 2>>"${MACHINE}/clipboard.log" &
  else echo "run-omarchy.sh: clipboard sharing needs the launcher app or python3; the machine starts without it" | tee -a "${MACHINE}/clipboard.log" >&2; fi
fi
exec "$QEMU" "$@"
