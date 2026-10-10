#!/bin/sh
# Boot a Windows machine on the Mac: Windows 11 for Arm on the accelerated QEMU runtime (tools/get-qemu-runtime.sh),
# from what tools/get-windows.sh keeps in out/windows (the ISO you downloaded from Microsoft, the virtio drivers, the
# UEFI firmware). The counterpart of run-omarchy.sh for Windows.
# A machine is a folder: its disk (a raw image, sparse, DISK_SIZE_GB), vars.fd (the firmware's own settings, its boot
# entries), uuid (the machine's own identity: every QEMU machine looks the same to Windows and to Microsoft without
# one), tools.iso (a small disc made here from windows/ and the drivers: Windows Setup reads autounattend.xml from
# it, and Windows runs mylinux\setup.cmd from it at every start), setup.log (what that script reports, through a virtio
# serial port) and the file "installed".
# Two phases, told apart by that file:
#  - installing (no "installed" yet): the machine starts from Microsoft's ISO with hardware Windows Setup has drivers
#    for (an NVMe disk, a USB keyboard and pointer, the firmware's own framebuffer at 1024x768). You choose language,
#    edition and account and accept Microsoft's licence terms in Setup; the answer file only turns off the checks this
#    machine cannot pass (no TPM, no Secure Boot here), lets a local account be made, and runs setup.cmd, which installs
#    the drivers and myLinux's helpers. A quarter of an hour to 40 minutes, with restarts by itself on the way, then Windows's first-run
#    screens, without a network (the network card's driver waits for their end, so a local account is offered);
#    setup.ps1 reports "installed" when they are over.
#  - installed: the display is a virtio card (driver viogpudo), which follows the window's size as Omarchy's does (the
#    title bar's size buttons, Fill Screen, a drag), with twice the pixels on a Retina display; one pointer, Windows's own,
#    drawn by Windows (the Mac's is hidden over the window); the clipboard is shared both ways (windows/mylinux-agent.ps1 inside, the launcher's or
#    tools/omarchy-clipboard.py's bridge here); sound through the Mac. Microsoft's ISO is no longer attached. Dragged
#    to a display of the other kind (Retina or not), the window keeps its size and Windows changes its scaling (the
#    launcher's helper tells it; from a terminal the scaling stays the start's). The ⌘ menu's Claude Install… and
#    Codex Install… are the launcher's wizards, which reach Windows through that helper too.
# Environment: RES=WxH window size in points (default: fills the display; a Retina display gives Windows twice that in
#              pixels, SCALE=1|2 overrides), DISK=path of the disk (default $MYLINUX_OUT/windows-machine/windows.raw),
#              DISK_SIZE_GB=64, NAME=window title, MEM=8G, CPUS=6,
#              GRAB=full|opt|none (every key to Windows, with Command as the Windows key and Option as Alt / Option
#              as the Windows key and macOS keeps its Command shortcuts / macOS keeps all of its own),
#              AUDIO=0 no sound device, CLIPBOARD=0 no clipboard sharing,
#              QMP=unix socket path for control (a clean stop is {"execute":"system_powerdown"} there: Windows shuts down),
#              FORWARD=host:guest[,...] TCP ports on 127.0.0.1, DISPLAY_CARD=basic the firmware's framebuffer also
#              for an installed Windows (its recovery screens have no virtio driver), TOOLS_EXTRA=dir more files for
#              the tools disc, DRYRUN=1 prints the QEMU command, MYLINUX_OUT=dir with windows/ and qemu-runtime/.
set -eu
REPO=$(cd "$(dirname "$0")" && pwd)
CALLER="$PWD"
cd "$REPO"
ME=run-windows.sh
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CALLER" "$1" ;; esac; }
die() { echo "$ME: $*" >&2; exit 1; }
have_python() {
  [ -x /opt/homebrew/bin/python3 ] || [ -x /usr/local/bin/python3 ] && return 0
  dev=$(xcode-select -p 2>/dev/null) || return 1
  case "$dev" in */CommandLineTools) [ -x "$dev/usr/bin/python3" ] ;; *) xcodebuild -license check >/dev/null 2>&1 ;; esac
}
# grow_file <path> <GB>: create the file or grow it to that size, sparse; never shrinks, keeps what is in it
grow_file() {
  want=$(( $2 * 1024 * 1024 * 1024 )); have=$(stat -f %z "$1" 2>/dev/null || echo 0)
  [ "$have" -ge "$want" ] || dd if=/dev/zero of="$1" bs=1 count=0 seek="$want" 2>/dev/null
}
OUT="${MYLINUX_OUT:+$(abs "$MYLINUX_OUT")}"; OUT="${OUT:-$REPO/out}"
export MYLINUX_OUT="$OUT"
G="$OUT/windows"
[ "$(MYLINUX_QEMU=auto sh tools/qemu-flavour.sh "$OUT")" = runtime ] || die "Windows needs the accelerated QEMU runtime: run tools/get-qemu-runtime.sh"
export MYLINUX_QEMU=runtime

NAME="${NAME:-Windows}"
MEM="${MEM:-8G}"
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
CPUS="${CPUS:-$(( NCPU > 8 ? 6 : (NCPU > 4 ? 4 : 2) ))}"
case "$CPUS" in ''|*[!0-9]*) die "CPUS must be a number" ;; esac
[ "$CPUS" -ge 1 ] && [ "$CPUS" -le "$NCPU" ] || die "CPUS out of range: $CPUS (this Mac has $NCPU)"
DISK=$(abs "${DISK:-$OUT/windows-machine/windows.raw}")
MACHINE=$(dirname "$DISK")
DISK_SIZE_GB="${DISK_SIZE_GB:-64}"
case "$DISK_SIZE_GB" in ''|*[!0-9]*) die "DISK_SIZE_GB must be a whole number of GB" ;; esac
[ "$DISK_SIZE_GB" -ge 32 ] && [ "$DISK_SIZE_GB" -le 2000 ] || die "DISK_SIZE_GB out of range: $DISK_SIZE_GB (32-2000)"
case "${GRAB:-full}" in
  full) KEYS="full-grab=on" ;;
  none) KEYS="full-grab=off" ;;
  opt)  KEYS="swap-opt-cmd=on" ;;
  *) die "GRAB must be full, opt or none" ;;
esac
case "${AUDIO:-1}" in 0|1) ;; *) die "AUDIO must be 0 or 1" ;; esac
case "${CLIPBOARD:-1}" in 0|1) ;; *) die "CLIPBOARD must be 0 or 1" ;; esac
case "${DISPLAY_CARD:-}" in ''|basic) ;; *) die "DISPLAY_CARD is basic or not set" ;; esac
CLIPSOCK="/tmp/mylinux-$(id -u)-clip-$$.sock"      # short: unix socket paths are limited to 104 bytes
KEYSOCK="/tmp/mylinux-$(id -u)-wkey-$$.sock"
HOSTSOCK="/tmp/mylinux-$(id -u)-host-$$.sock"
NETDEV="user,id=n0"
for fw in $(printf '%s' "${FORWARD:-}" | tr ',' ' '); do
  case "$fw" in [0-9]*:[0-9]*) NETDEV="$NETDEV,hostfwd=tcp:127.0.0.1:${fw%%:*}-:${fw##*:}" ;; *) die "FORWARD entries look like hostport:guestport (got '$fw')" ;; esac
done

# ---- installing or installed ---------------------------------------------------------------------------------------
# Windows says so itself: setup.ps1's word when the first-run screens were over, in the run before this one, through
# the virtio port
if [ "${DRYRUN:-0}" != 1 ] && [ ! -f "$MACHINE/installed" ] && grep -q '^mylinux-setup: installed' "$MACHINE/setup.log" 2>/dev/null; then
  : > "$MACHINE/installed"
fi
INSTALLED=0; [ -f "$MACHINE/installed" ] && INSTALLED=1
[ "${DRYRUN:-0}" = 1 ] && [ -n "${INSTALLED_DRYRUN:-}" ] && INSTALLED=$INSTALLED_DRYRUN
[ -s "$G/edk2-aarch64-code.fd" ] || die "the UEFI firmware is missing: run tools/get-windows.sh"
if [ "$INSTALLED" = 0 ]; then
  [ -s "$G/windows.iso" ] || die "Windows is not there to install: download the Arm64 ISO from microsoft.com/software-download/windows11arm64, then run tools/get-windows.sh --iso <file>"
  [ -s "$G/drivers/NetKVM/netkvm.inf" ] && [ -s "$G/drivers/viogpudo/viogpudo.inf" ] && [ -s "$G/drivers/vioserial/vioser.inf" ] || die "the virtio drivers are missing: run tools/get-windows.sh"
fi

# ---- the window -------------------------------------------------------------------------------------------------------
if [ "$INSTALLED" = 1 ] && [ -z "${DISPLAY_CARD:-}" ]; then
  # the virtio display: Windows takes the size the window asks for, twice the points on a Retina display
  . "$REPO/tools/desktop-window.sh"
  DISPLAY_DEVS="-device virtio-gpu-pci,id=vgpu,max_outputs=1,xres=$GX,yres=$GY,romfile="
  # gl=es: the window's GL drawing, as Omarchy's has. Windows draws in 2D either way; QEMU's plain drawing tells the
  # guest a wrong size for a zoomed window (the wanted size times the zoom), and Windows followed that
  # show-cursor=off: the Mac's own pointer is hidden over the window. Windows's pointer is there, drawn by Windows into
  # its picture as while it installs, and with the Mac's shown as well there were two. (The display driver's other
  # way, the pointer handed to the window to draw, left scraps of a larger pointer under a smaller one: setup.ps1.)
  DISPLAY_OPTS="cocoa,gl=es,show-cursor=off,zoom-to-fit=off,$KEYS"
  HIDPI=true                              # one pixel of Windows is one pixel of the display
  export MYLINUX_DESKTOP_MODE="${GX}x${GY}"
  # the size Windows starts at, in words its agent reads (windows/mylinux-agent.ps1: SMBIOS OEM strings)
  SMBIOS="-smbios type=11,value=mylinux.res=${GX}x${GY},value=mylinux.scale=$SCALE,value=mylinux.run=$$-$(date +%s)"
  # The window on another display: the launcher's helper tells Windows which kind it is on now (the virtio port
  # dev.mylinux.host: "scale=1" or "scale=2", that display's pixels to a point), the agent sets Windows's scaling by
  # it, and the runtime keeps the window's size when it comes onto a display of the other kind (MYLINUX_GUEST_SCALES),
  # so Windows gets half or twice the pixels and looks the same. Started from a terminal there is no helper: the
  # scaling stays the start's, and the window takes the mode's size on the other display, as the Linux desktops' does.
  HOSTPORT=0; [ -n "${MYLINUX_HELPER:-}" ] && [ -x "$MYLINUX_HELPER" ] && HOSTPORT=1
else
  # Windows Setup, and Windows before its virtio driver: the firmware's framebuffer (1024x768 in a machine made with
  # windows/vars.fd.gz, 800x600 in an older one), scaled to the window when the title bar's + or Fill Screen enlarge it
  RES="${RES:-1024x768}"; SCALE=1; GX=1024; GY=768
  DISPLAY_DEVS="-device ramfb"
  DISPLAY_OPTS="cocoa,show-cursor=off,zoom-to-fit=on,$KEYS"
  HIDPI=false                             # 1024x768 points, not a quarter of that on a Retina display
  SMBIOS=""; HOSTPORT=0
fi
export MYLINUX_SIZE_BUTTONS=1             # the window's size buttons: − + Fill Screen and full screen
# Windows's Caps Lock is what its keyboard's light says, and is kept like the Mac's by it (runtime 11.1.1-22): the
# window used to count the presses it sent, and one that Windows did not take while it started left the two the
# wrong way round, on in Windows when off on the Mac
export MYLINUX_CAPS_LOCK_LIGHT=1
# the ⌘ menu in the title bar (⌘P opens it): the launcher's commands that fit Windows
export MYLINUX_COMMANDS_MENU="claude codex snippets share"

# ---- the machine's files ------------------------------------------------------------------------------------------------
TOOLS="$MACHINE/tools.iso"
if [ "${DRYRUN:-0}" != 1 ]; then
  mkdir -p "$MACHINE"
  [ -f "$DISK" ] || echo "creating $DISK ($DISK_SIZE_GB GB, sparse) ..."
  grow_file "$DISK" "$DISK_SIZE_GB" || die "could not create the disk"
  # the firmware's variables (its boot entries): a writable flash of its own, the size of the code flash. A new machine's
  # come from windows/vars.fd.gz (tools/make-windows-vars.py), where the firmware's screen is 1024x768, the largest it has
  # for Windows Setup to draw on; an empty one (800x600) if that cannot be unpacked
  # (and on a display too low for a 1024x768 window below its menu bar: a small Mac at its larger text sizes)
  roomy() { ( die() { exit 1; }; RES=1024x768; SCALE=1; . "$REPO/tools/desktop-window.sh" >/dev/null 2>&1; [ "$RES" = 1024x768 ] ); }
  if [ ! -f "$MACHINE/vars.fd" ]; then
    if roomy && gunzip -c windows/vars.fd.gz > "$MACHINE/vars.fd.new" 2>/dev/null && [ "$(stat -f %z "$MACHINE/vars.fd.new")" = 67108864 ]; then
      mv "$MACHINE/vars.fd.new" "$MACHINE/vars.fd"
    else
      rm -f "$MACHINE/vars.fd.new"; dd if=/dev/zero of="$MACHINE/vars.fd" bs=1m count=64 2>/dev/null || die "could not create vars.fd"
    fi
  fi
  case "$(cat "$MACHINE/uuid" 2>/dev/null)" in ????????-????-????-????-????????????) ;; *) uuidgen | tr 'A-F' 'a-f' > "$MACHINE/uuid" ;; esac
  # the tools disc: made again when what goes on it changed (a newer launcher's scripts reach Windows at its next start)
  if [ -d "$G/drivers" ]; then
    STAMP=$( { cat windows/autounattend.xml windows/setup.cmd windows/setup.ps1 windows/mylinux-agent.ps1; find "$G/drivers" ${TOOLS_EXTRA:+"$TOOLS_EXTRA"} -type f -exec cksum {} +; } | cksum)
    if [ ! -s "$TOOLS" ] || [ "$(cat "$MACHINE/tools.stamp" 2>/dev/null)" != "$STAMP" ]; then
      T="$MACHINE/.tools"; NEWISO="$MACHINE/.tools-new.iso"       # (hdiutil adds .iso to a name that lacks it)
      rm -rf "$T" "$NEWISO"; mkdir -p "$T/mylinux"
      cp windows/autounattend.xml "$T/"
      cp windows/setup.cmd windows/setup.ps1 windows/mylinux-agent.ps1 "$T/mylinux/"
      cp -R "$G/drivers" "$T/drivers"
      [ -z "${TOOLS_EXTRA:-}" ] || cp -R "$TOOLS_EXTRA"/. "$T/"
      hdiutil makehybrid -quiet -iso -joliet -default-volume-name MYLINUX -o "$NEWISO" "$T" || { rm -rf "$T" "$NEWISO"; die "could not make the tools disc"; }
      mv -f "$NEWISO" "$TOOLS"; rm -rf "$T"; printf '%s\n' "$STAMP" > "$MACHINE/tools.stamp"
    fi
  fi
fi

# ---- the machine ----------------------------------------------------------------------------------------------------------
# Its own identity (system UUID, and a network address made from it): QEMU's defaults are the same in every machine
# anywhere, and Windows's licensing and Microsoft's device services tell machines apart by these.
UUID=$(cat "$MACHINE/uuid" 2>/dev/null || true)
case "$UUID" in ????????-????-????-????-????????????) ;; *) UUID=$(uuidgen | tr 'A-F' 'a-f') ;; esac
MAC="52:54:00:$(printf '%s' "$UUID" | cut -c1-2):$(printf '%s' "$UUID" | cut -c3-4):$(printf '%s' "$UUID" | cut -c5-6)"
# Two settings Windows needs here, each found by a failure: gic-version=3 is Apple's own interrupt controller (with
# QEMU's v2m frame for the devices' message interrupts), and highmem-mmio=off keeps every PCI device's memory below 4 GB:
# with QEMU's high window the virtio network driver hung as it was installed, and Windows's first-run setup with it.
set -- \
  -name "$NAME" -M virt,gic-version=3,highmem-mmio=off -accel hvf -cpu host -smp "$CPUS" -m "$MEM" -uuid "$UUID" \
  -drive "if=pflash,format=raw,readonly=on,file=$G/edk2-aarch64-code.fd" -drive "if=pflash,format=raw,file=$MACHINE/vars.fd" \
  $DISPLAY_DEVS $SMBIOS \
  -device qemu-xhci,id=usb -device usb-kbd,bus=usb.0 -device usb-tablet,bus=usb.0 \
  -drive "if=none,id=sys,file=$DISK,format=raw,cache=writeback,discard=unmap" -device nvme,drive=sys,serial=mylinux-windows,bootindex=1 \
  -netdev "$NETDEV" -device "virtio-net-pci,netdev=n0,mac=$MAC,romfile=" \
  -device virtio-serial-pci,id=ser,romfile= \
  -chardev "file,id=mlsetup,path=$MACHINE/setup.log" -device "virtserialport,bus=ser.0,nr=1,chardev=mlsetup,name=dev.mylinux.setup" \
  -rtc base=localtime \
  -display "$DISPLAY_OPTS"
# Microsoft's ISO only while Windows is being installed; the firmware starts it when a key is pressed (see below)
if [ "$INSTALLED" = 0 ]; then
  set -- "$@" -drive "if=none,id=wincd,file=$G/windows.iso,media=cdrom,readonly=on,format=raw" -device usb-storage,bus=usb.0,drive=wincd,bootindex=0
fi
if [ -s "$TOOLS" ] || [ "${DRYRUN:-0}" = 1 ]; then
  set -- "$@" -drive "if=none,id=toolscd,file=$TOOLS,media=cdrom,readonly=on,format=raw" -device usb-storage,bus=usb.0,drive=toolscd
fi
if [ "${CLIPBOARD:-1}" = 1 ]; then
  # the port windows/mylinux-agent.ps1 opens (Omarchy's name and protocol); the Mac side is the launcher, or tools/omarchy-clipboard.py
  set -- "$@" -chardev "socket,id=clip,path=$CLIPSOCK,server=on,wait=off" \
    -device "virtserialport,bus=ser.0,nr=2,chardev=clip,name=dev.tryomarchy.clipboard"
fi
if [ "$HOSTPORT" = 1 ]; then
  set -- "$@" -chardev "socket,id=mlhost,path=$HOSTSOCK,server=on,wait=off" \
    -device "virtserialport,bus=ser.0,nr=3,chardev=mlhost,name=dev.mylinux.host"
  export MYLINUX_GUEST_SCALES=1
fi
if [ "${AUDIO:-1}" = 1 ]; then
  set -- "$@" -audiodev sdl,id=audio -device intel-hda,id=hda,romfile= -device hda-duplex,bus=hda.0,audiodev=audio
fi
[ -z "${QMP:-}" ] || set -- "$@" -qmp "unix:$QMP,server=on,wait=off"
# A disk Windows Setup has not partitioned yet: the firmware offers "Press any key to boot from CD or DVD" for a few
# seconds and gives up; the key is pressed here, through a control socket of this script's own.
PRESS=0
if [ "$INSTALLED" = 0 ] && [ "${DRYRUN:-0}" != 1 ] && [ "$(dd if="$DISK" bs=512 skip=1 count=1 2>/dev/null | head -c 8)" != "EFI PART" ]; then
  PRESS=1; set -- "$@" -qmp "unix:$KEYSOCK,server=on,wait=off"
fi
if [ "${DRYRUN:-0}" = 1 ]; then
  echo "RES=$RES SCALE=$SCALE DISK=$DISK NAME=$NAME CPUS=$CPUS MEM=$MEM INSTALLED=$INSTALLED"
  for a in "$@"; do printf '%s\n' "$a"; done
  exit 0
fi
# With APP_ID (the launcher's machines) the machine has a bundle of its own, named after it: its own app in ⌘Tab.
# (the desktops' wrapper, Retina-capable or not as this phase needs)
BUNDLE=$(MYLINUX_BUNDLE=omarchy MYLINUX_BUNDLE_HIDPI=$HIDPI tools/make-app-bundle.sh | sed -n 's/ ready$//p' | tail -1) || true
[ -n "$BUNDLE" ] || die "could not prepare the machine's app"
QEMU="$BUNDLE/Contents/MacOS/qemu-myLinux"
[ -x "$QEMU" ] || die "$QEMU is missing"
if [ "$PRESS" = 1 ]; then
  # Return twice a second for the first twelve seconds, once QEMU has made the socket: the firmware asks within that
  # time, and Windows Setup's first page is not up yet to take a key as its answer
  ( i=0; while [ ! -S "$KEYSOCK" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    { printf '{"execute":"qmp_capabilities"}\n'
      i=0; while [ "$i" -lt 24 ]; do printf '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}\n'; sleep 0.5; i=$((i + 1)); done
    } | nc -U "$KEYSOCK" >/dev/null 2>&1
    rm -f "$KEYSOCK" ) &
fi
# the clipboard bridge connects once QEMU has made the socket and leaves when QEMU (its parent after the exec) is gone
if [ "${CLIPBOARD:-1}" = 1 ]; then
  rm -f "$CLIPSOCK"
  if [ -n "${MYLINUX_HELPER:-}" ] && [ -x "$MYLINUX_HELPER" ]; then "$MYLINUX_HELPER" --omarchy-clipboard "$CLIPSOCK" 2>>"${MACHINE}/clipboard.log" &
  elif have_python; then python3 tools/omarchy-clipboard.py "$CLIPSOCK" 2>>"${MACHINE}/clipboard.log" &
  else echo "$ME: clipboard sharing needs the launcher app or python3; the machine starts without it" | tee -a "${MACHINE}/clipboard.log" >&2; fi
fi
# the helper for the display's kind: as the clipboard's, it leaves when QEMU is gone
if [ "$HOSTPORT" = 1 ]; then
  rm -f "$HOSTSOCK"
  rm -f "$MACHINE/guest-memory"            # (Windows's own memory figure, kept by the helper for the launcher's sidebar)
  # "$MACHINE/link": where the launcher's wizards (Claude Install…, Codex Install… in the ⌘ menu) leave their questions
  # for Windows and read its answers; the helper carries them over the same port (WindowsLink.swift)
  rm -rf "$MACHINE/link"
  "$MYLINUX_HELPER" --windows-display "$HOSTSOCK" "$MACHINE/guest-memory" "$MACHINE/link" 2>>"${MACHINE}/display.log" &
fi
exec "$QEMU" "$@"
