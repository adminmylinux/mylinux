#!/bin/sh
# Boot an Omarchy machine on the Mac: the Try Omarchy guest (tools/get-omarchy.sh) on the accelerated QEMU runtime
# (tools/get-qemu-runtime.sh), Hyprland drawn by the Mac's GPU. The counterpart of run.sh for the second machine kind.
# A machine is a folder: its root disk (a raw ext4 image unpacked from the downloaded factory disk on first start,
# grown to DISK_SIZE_GB; the guest enlarges its filesystem on boot) and boot/, the kernel and initramfs that disk
# was created with (they must match the modules on the disk, so a newer download never replaces them).
# Environment: RES=WxH (default: fits the screen under the mouse pointer), DISK=path of the root disk (default $MYLINUX_OUT/omarchy-machine/omarchy.ext4), DISK_SIZE_GB=32,
#              NAME=window title, MEM=8G, CPUS=6, SHARE_DIR=folder shown inside Omarchy as ~/<its name> (optional),
#              GRAB=opt|full|none (as run.sh: Option acts as Super / every key to the guest / neither),
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
OUT="${MYLINUX_OUT:+$(abs "$MYLINUX_OUT")}"; OUT="${OUT:-$REPO/out}"
export MYLINUX_OUT="$OUT"
G="$OUT/omarchy"

[ "$(MYLINUX_QEMU=auto sh tools/qemu-flavour.sh "$OUT")" = runtime ] || die "Omarchy needs the accelerated QEMU runtime: run tools/get-qemu-runtime.sh"
export MYLINUX_QEMU=runtime
# ---- guest resolution: as run.sh, the display under the mouse pointer in points, minus window margins ----------
# The window is not resizable (zoom-to-fit=off) and is exactly the guest's size: the runtime's Cocoa display scales a
# text console wrongly whenever window and guest mode differ, which would garble Omarchy's first-boot setup screen.
if [ -z "${RES:-}" ]; then
  SCREEN=$(osascript -l JavaScript -e '
    ObjC.import("AppKit");
    const m = $.NSEvent.mouseLocation, all = $.NSScreen.screens;
    let s = $.NSScreen.mainScreen;
    for (let i = 0; i < all.count; i++) { const f = all.objectAtIndex(i).frame;
      if (m.x >= f.origin.x && m.x < f.origin.x + f.size.width && m.y >= f.origin.y && m.y < f.origin.y + f.size.height) s = all.objectAtIndex(i); }
    const v = s.visibleFrame; [Math.round(v.size.width), Math.round(v.size.height)].join(" ")' 2>/dev/null || true)
  SW=${SCREEN%% *}; SH=${SCREEN#* }
  case "$SW$SH" in ''|*[!0-9]*) RES=1600x1000 ;; *) if [ "$SW" -gt 800 ]; then RES="$(( (SW - 40) / 8 * 8 ))x$(( (SH - 40 - 28) / 8 * 8 ))"; else RES=1600x1000; fi ;; esac
fi
case "$RES" in [0-9]*x[0-9]*) XRES="${RES%x*}"; YRES="${RES#*x}" ;; *) die "RES must look like 1920x1200 (got '$RES')" ;; esac
[ "$XRES" -ge 640 ] && [ "$XRES" -le 8192 ] && [ "$YRES" -ge 480 ] && [ "$YRES" -le 8192 ] || die "RES out of range: $RES"

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
  case "$SHARE_DIR" in /|/Users|/private|/tmp|/private/tmp|/System|/Library|/Applications|/Volumes|"$HOME"|"$HOME/Library"|"$HOME/Library"/*) die "refusing to share $SHARE_DIR" ;; esac
  SHARE_NAME=$(printf '%s' "$(basename "$SHARE_DIR")" | base64 | tr '+/' '-_' | tr -d '=\n')
  APPEND="$APPEND omarchy.shared_folder_name=$SHARE_NAME"
fi

# ---- first start of this machine: unpack the factory disk, grow it, keep the matching kernel beside it ----------
if [ "${DRYRUN:-0}" != 1 ] && { [ ! -f "$DISK" ] || [ ! -s "$MACHINE/boot/vmlinuz-linux" ] || [ ! -s "$MACHINE/boot/initramfs-linux.img" ]; }; then
  [ -s "$G/rootfs.ext4.zst" ] && [ -s "$G/vmlinuz-linux" ] && [ -s "$G/initramfs-linux.img" ] || die "the Omarchy guest is not downloaded: run tools/get-omarchy.sh"
  [ ! -f "$DISK" ] || die "$DISK exists but $MACHINE/boot (its kernel and initramfs) is missing; restore it or move the disk away"
  mkdir -p "$MACHINE/boot"
  echo "creating $DISK ($DISK_SIZE_GB GB, sparse) from Omarchy $(cat "$G/OMARCHY-REVISION" 2>/dev/null) ..."
  "$OUT/qemu-runtime/bin/zstd" -d -q -f --sparse -o "$DISK.new" "$G/rootfs.ext4.zst" || { rm -f "$DISK.new"; die "could not unpack the root disk"; }
  python3 -c 'import sys,os; s=int(sys.argv[2])*2**30; f=open(sys.argv[1],"r+b"); s>os.path.getsize(sys.argv[1]) and f.truncate(s)' "$DISK.new" "$DISK_SIZE_GB"
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
  -device "virtio-gpu-gl-pci,max_outputs=1,xres=$XRES,yres=$YRES,romfile=" \
  -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
  -netdev "$NETDEV" -device virtio-net-pci,netdev=n0,romfile= \
  -audiodev sdl,id=audio -device intel-hda,id=hda,romfile= -device hda-micro,bus=hda.0,audiodev=audio \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0,romfile= \
  -device virtio-balloon-pci,romfile= \
  -device virtio-serial-pci,id=ser,romfile= -chardev "$CONSOLE" -device virtconsole,bus=ser.0,nr=0,chardev=hvc0 \
  -display "cocoa,gl=es,show-cursor=on,zoom-to-fit=off,$KEYS" \
  "$@"
if [ -n "$SHARE_DIR" ]; then
  set -- "$@" -fsdev "local,id=share,path=$SHARE_DIR,security_model=none,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000" \
    -device "virtio-9p-pci,fsdev=share,mount_tag=mac,romfile="
fi
[ -z "${QMP:-}" ] || set -- "$@" -qmp "unix:$QMP,server=on,wait=off"
if [ "${DRYRUN:-0}" = 1 ]; then
  echo "RES=$RES DISK=$DISK SHARE_DIR=$SHARE_DIR NAME=$NAME CPUS=$CPUS MEM=$MEM"
  for a in "$@"; do printf '%s\n' "$a"; done
  exit 0
fi
MYLINUX_BUNDLE=omarchy tools/make-app-bundle.sh >/dev/null || die "could not prepare $OUT/myLinux-omarchy.app"
[ -x "$QEMU" ] || die "$QEMU is missing"
exec "$QEMU" "$@"
