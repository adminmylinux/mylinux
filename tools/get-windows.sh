#!/bin/sh
# What a Windows machine is made of, into out/windows (or $MYLINUX_OUT/windows; the Mac launcher app does this), for
# run-windows.sh: Windows 11 for Arm in the accelerated QEMU runtime.
#  - Windows itself is Microsoft's and comes from Microsoft: the "Windows 11 (multi-edition ISO for Arm64)" that
#    https://www.microsoft.com/software-download/windows11arm64 gives after its questions (about 8 GB; the link it
#    hands out is personal and lasts a day, so no script can fetch it). --iso takes the file you downloaded: it is
#    checked (an Arm64 Windows installer: its boot loader and its install image are there) and kept as windows.iso, a
#    clone where the volume can (no second 8 GB). It is needed until Windows is installed in a machine.
#  - The virtio drivers Windows lacks for this machine's network card, display and serial ports: the Arm64 Windows 11
#    builds of NetKVM, viogpudo (with its resolution service) and vioserial, from the virtio-win project's driver disc
#    (fedorapeople.org, one pinned version, checked against a pinned SHA-256; 877 MB to download, 3 MB kept, with the
#    project's licence beside them). run-windows.sh puts them on a small tools disc of each machine.
#  - The UEFI firmware (tools/get-edk2.sh: QEMU's own edk2 build).
# Usage: tools/get-windows.sh --iso <file>   everything; the ISO from that file
#        tools/get-windows.sh                the drivers and the firmware (an ISO already kept stays)
#        tools/get-windows.sh --remove       delete it all (machines keep their own disks)
#        tools/get-windows.sh --check        the saved and the latest revision (tools/download-cache.sh)
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
VIRTIO_VERSION=0.1.302
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$VIRTIO_VERSION-1/virtio-win-$VIRTIO_VERSION.iso"
VIRTIO_SHA256=303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d
REVISION="virtio-win $VIRTIO_VERSION"
FETCH="--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/windows"
ISO=""
case "${1:-}" in
  --remove) rm -rf "$DEST" "$OUT/.staging-windows"; echo "removed $DEST"; exit 0 ;;
  --check) check_report "$(cat "$DEST/WINDOWS-REVISION" 2>/dev/null || true)" "$REVISION"; exit 0 ;;
  --iso) ISO=${2:?--iso needs the file Microsoft gave you}; [ $# = 2 ] || { echo "usage: tools/get-windows.sh [--iso <file>]" >&2; exit 64; } ;;
  "") ;;
  *) echo "usage: tools/get-windows.sh [--iso <file> | --remove | --check]" >&2; exit 64 ;;
esac
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Windows machine is for Apple-silicon Macs" >&2; exit 1; }
die() { echo "$*" >&2; exit 1; }
mkdir -p "$DEST"
STAGE="$OUT/.staging-windows"; MNT=""
cleanup() { [ -z "$MNT" ] || hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$STAGE"; }
rm -rf "$STAGE"; mkdir -p "$STAGE"; trap cleanup EXIT
# a disc image's files, read-only and out of the Finder's sight; nothing from it runs on the Mac
attach() { MNT="$STAGE/mnt"; mkdir -p "$MNT"; hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$1" || { MNT=""; return 1; }; }
detach() { hdiutil detach -quiet "$MNT" 2>/dev/null || hdiutil detach -quiet -force "$MNT" 2>/dev/null || true; MNT=""; }

# ---- the ISO from Microsoft -------------------------------------------------------------------------------------------
if [ -n "$ISO" ]; then
  [ -f "$ISO" ] && [ -r "$ISO" ] || die "$ISO is not a file that can be read"
  echo "checking $(basename "$ISO") ..."
  # (macOS asks before an app reads Downloads, Desktop or Documents; a "no" there looks the same as a broken file)
  attach "$ISO" || die "$(basename "$ISO") could not be opened as a disc image. If macOS asked whether this app may read the folder it is in, allow that and choose the file again"
  # any case: the disc's file system keeps upper case on some builds and lower on others
  has() { find "$MNT" -maxdepth 3 -ipath "$MNT/$1" 2>/dev/null | grep -q .; }
  if ! has "efi/boot/bootaa64.efi"; then
    X86=0; has "efi/boot/bootx64.efi" && X86=1
    detach
    [ "$X86" = 0 ] || die "that is Windows for Intel and AMD PCs (x64), which does not run here: the Arm64 ISO is at microsoft.com/software-download/windows11arm64"
    die "$(basename "$ISO") has no Arm64 boot loader: it is not a Windows 11 for Arm installer"
  fi
  has "sources/install.wim" || has "sources/install.esd" || { detach; die "$(basename "$ISO") has no Windows install image (sources/install.wim)"; }
  LABEL=$(basename "$(diskutil info "$MNT" 2>/dev/null | sed -n 's/^ *Volume Name: *//p' | head -1)")
  detach
  echo "keeping it as $DEST/windows.iso ..."
  rm -f "$DEST/windows.iso.new"
  cp -c "$ISO" "$DEST/windows.iso.new" 2>/dev/null || cp "$ISO" "$DEST/windows.iso.new" || { rm -f "$DEST/windows.iso.new"; die "could not copy the ISO (is the disk full?)"; }
  mv -f "$DEST/windows.iso.new" "$DEST/windows.iso"
  printf '%s\n' "${LABEL:-Windows 11 for Arm}" > "$DEST/WINDOWS-ISO"
fi

# ---- the drivers --------------------------------------------------------------------------------------------------------
complete() {
  [ -s "$1/NetKVM/netkvm.inf" ] && [ -s "$1/NetKVM/netkvm.sys" ] && [ -s "$1/viogpudo/viogpudo.inf" ] && [ -s "$1/viogpudo/viogpudo.sys" ] \
    && [ -s "$1/viogpudo/vgpusrv.exe" ] && [ -s "$1/viogpudo/viogpuap.exe" ] && [ -s "$1/vioserial/vioser.inf" ] && [ -s "$1/vioserial/vioser.sys" ]
}
if [ "$(cat "$DEST/WINDOWS-REVISION" 2>/dev/null)" = "$REVISION" ] && complete "$DEST/drivers"; then
  echo "the drivers are already $REVISION"
else
  VISO="$STAGE/virtio-win.iso"
  # a driver disc someone already has (the same file, by its checksum) saves the download
  if [ -n "${MYLINUX_VIRTIO_ISO:-}" ] && [ -f "$MYLINUX_VIRTIO_ISO" ]; then
    cp -c "$MYLINUX_VIRTIO_ISO" "$VISO" 2>/dev/null || cp "$MYLINUX_VIRTIO_ISO" "$VISO"
  else
    echo "downloading the virtio drivers for Windows ($REVISION, 877 MB) ..."
    # shellcheck disable=SC2086
    curl -fL $FETCH --progress-bar -o "$VISO" "$VIRTIO_URL" || die "could not download the driver disc from fedorapeople.org; try again in a few minutes"
  fi
  [ "$(shasum -a 256 "$VISO" | cut -d' ' -f1)" = "$VIRTIO_SHA256" ] || die "the driver disc does not match its pinned checksum: nothing installed"
  attach "$VISO" || die "the driver disc could not be opened"
  NEW="$STAGE/drivers"; mkdir -p "$NEW"
  for d in NetKVM viogpudo vioserial; do
    [ -d "$MNT/$d/w11/ARM64" ] || { detach; die "the driver disc has no Arm64 Windows 11 build of $d"; }
    mkdir -p "$NEW/$d"
    # the drivers and their helpers, not the debug symbols
    for f in "$MNT/$d/w11/ARM64"/*; do case "$f" in *.pdb) ;; *) cp "$f" "$NEW/$d/" ;; esac; done
  done
  cp "$MNT/virtio-win_license.txt" "$NEW/virtio-win_license.txt" 2>/dev/null || true
  detach
  chmod -R u+w "$NEW"
  complete "$NEW" || die "the driver disc lacks a file a Windows machine needs: nothing installed"
  rm -rf "$DEST/drivers.prev"; [ ! -d "$DEST/drivers" ] || mv "$DEST/drivers" "$DEST/drivers.prev"
  mv "$NEW" "$DEST/drivers"; rm -rf "$DEST/drivers.prev"
  printf '%s\n' "$REVISION" > "$DEST/WINDOWS-REVISION"
fi

# ---- the firmware -------------------------------------------------------------------------------------------------------
[ -s "$DEST/edk2-aarch64-code.fd" ] || sh tools/get-edk2.sh "$DEST"

if [ -s "$DEST/windows.iso" ]; then
  echo "ok: $DEST has $(cat "$DEST/WINDOWS-ISO" 2>/dev/null || echo "the Windows ISO"), the drivers ($REVISION) and the firmware. Start a machine with ./run-windows.sh"
else
  echo "ok: $DEST has the drivers ($REVISION) and the firmware. Windows itself is Microsoft's: download the Arm64 ISO from microsoft.com/software-download/windows11arm64, then run tools/get-windows.sh --iso <file>"
fi
