#!/bin/sh
# myLinux: builds the Omarchy machine image from Omarchy's own release ISO for aarch64, on this Mac:
#   1. the ISO, pinned by its SHA-256 (taken from a download whose signature checked out against Omarchy's release key,
#      40DFB630FF42BCFFB047046CF0134EE680CAC571, the one omarchy.org's manual names)
#   2. Omarchy's unattended install of it (a CIDATA drive with the configurator's answers, deferred provisioning: no
#      user, the first start of each machine makes one), in a QEMU machine of the launcher's runtime with nothing on
#      the screen; QEMU ends when the installer reboots, so the new system has never started
#   3. offline, as root in the OrbStack "debian" machine (tools/omarchy-image-root.sh finish): Try Omarchy's guest
#      package (its Mac integration: the share, the clipboard, the power button, disk growth, Retina, the M4's SME),
#      built from its pinned source, and myLinux's pieces (omarchy/native, omarchy/answers, omarchy/session)
#   4. the disk compressed, <out>/omarchy.raw.zst, and in 1 GB parts with SHA256SUMS (what tools/get-omarchy.sh downloads)
# Usage: tools/build-omarchy-image.sh [out-dir]          (default out/omarchy-build)
#        STAGE=install|finish runs one step again on what is there
set -eu
cd "$(dirname "$0")/.."
REPO=$PWD
VERSION=4.5.0
REVISION=$VERSION-1                     # the image's own revision: bump it for a rebuild of the same Omarchy
ISO_URL=https://iso.omarchy.org/omarchy-$VERSION-aarch64.iso
ISO_SHA256=c9a9dd1107c10924eeb1e885226f9884080b1ffbf227d1f7f9ad255e4cebfb17
TRY_COMMIT=bb217b29e9517556924cd62e81c621dc9b967a44              # github.com/omacom/try-omarchy (MIT)
TRY_SHA256=9619535bab87412a63e67619e8e90a7485c3d65df1debd4320f95be8c6ab0057
DISK_GB=12                              # the image's disk; a machine's grows to its own size at its first start
OUT=$(mkdir -p "${1:-out/omarchy-build}" && cd "${1:-out/omarchy-build}" && pwd)
W=$OUT/work; mkdir -p "$W"
QEMU=$REPO/out/qemu-runtime/bin/qemu-system-aarch64
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
[ -x "$QEMU" ] || die "no QEMU runtime: run tools/get-qemu-runtime.sh"
command -v orb >/dev/null || die "needs OrbStack's debian machine (orb)"
[ -s out/debian/edk2-aarch64-code.fd ] || sh tools/get-edk2.sh out/debian
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
root() { orb -m debian sudo env PATH=/usr/sbin:/usr/bin:/sbin:/bin bash "$REPO/tools/omarchy-image-root.sh" "$@"; }

# ---- 1. the ISO ---------------------------------------------------------------------------------------------------
ISO=$OUT/omarchy-$VERSION-aarch64.iso
[ -f "$ISO" ] && [ "$(sha "$ISO")" = "$ISO_SHA256" ] || {
  say "Downloading $ISO_URL (6 GB)"
  curl -fL --retry 3 --retry-delay 3 -C - -o "$ISO" "$ISO_URL" || die "download failed"
  [ "$(sha "$ISO")" = "$ISO_SHA256" ] || { rm -f "$ISO"; die "the ISO does not match its pinned SHA-256"; }
}

# ---- 2. Omarchy's unattended install --------------------------------------------------------------------------------
if [ "${STAGE:-install}" = install ]; then
  root cidata "$W" "$DISK_GB"
  rm -f "$W/disk.raw" "$W/vars.fd"; truncate -s "${DISK_GB}G" "$W/disk.raw"; truncate -s 64M "$W/vars.fd"
  say "Installing Omarchy $VERSION (unattended, no window; a few minutes)"
  t0=$(date +%s)
  # bootindex: the empty disk first, so the firmware falls through to the ISO; -no-reboot ends QEMU at the installer's
  # reboot, before the new system starts. Option ROMs are off: the runtime carries none.
  "$QEMU" -name omarchy-image-install -M virt,gic-version=3 -accel hvf -cpu host,pmu=off -smp 6 -m 8G -no-reboot \
    -drive "if=pflash,format=raw,readonly=on,file=$REPO/out/debian/edk2-aarch64-code.fd" -drive "if=pflash,format=raw,file=$W/vars.fd" \
    -drive "file=$W/disk.raw,format=raw,if=none,id=target" -device virtio-blk-pci,drive=target,bootindex=0,romfile= \
    -device virtio-scsi-pci,romfile= -drive "file=$ISO,format=raw,if=none,id=iso,media=cdrom,readonly=on" \
    -device scsi-cd,drive=iso,bootindex=1 \
    -device qemu-xhci -drive "file=$W/cidata.img,format=raw,if=none,id=cidata" -device usb-storage,drive=cidata \
    -device virtio-gpu-pci,romfile= -device virtio-rng-pci,romfile= \
    -netdev user,id=net -device virtio-net-pci,netdev=net,romfile= \
    -serial "file:$W/install-serial.log" -display none > "$W/install-qemu.log" 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    [ $(( $(date +%s) - t0 )) -lt 1800 ] || { kill $pid; die "the install took more than 30 minutes"; }
    sleep 5
  done
  wait $pid || die "QEMU failed: $(tail -3 "$W/install-qemu.log")"
  # the installed disk has a GPT ("EFI PART" in its second sector)
  [ "$(dd if="$W/disk.raw" bs=512 skip=1 count=1 2>/dev/null | head -c 8)" = "EFI PART" ] || die "the disk has no partition table: the install did not happen"
  say "Installed in $(( $(date +%s) - t0 )) s"
fi

# ---- 3. Try Omarchy's guest package and myLinux's pieces, offline -------------------------------------------------
TRY=$W/try-omarchy-$TRY_COMMIT.tar.gz
[ -f "$TRY" ] && [ "$(sha "$TRY")" = "$TRY_SHA256" ] || {
  curl -fsSL -o "$TRY" "https://codeload.github.com/omacom/try-omarchy/tar.gz/$TRY_COMMIT" || die "could not download Try Omarchy's source"
  [ "$(sha "$TRY")" = "$TRY_SHA256" ] || { rm -f "$TRY"; die "Try Omarchy's source does not match its pinned SHA-256"; }
}
# the installed disk stays as it came (a clone, free on APFS): this step can be run again on it
rm -f "$W/image.raw"; cp -c "$W/disk.raw" "$W/image.raw"
root finish "$W/image.raw" "$TRY" "$REPO"

# ---- 4. compressed, with its checksums, in parts a GitHub release takes (2 GB at most each) -----------------------
say "Compressing"
rm -f "$OUT"/omarchy.raw.zst*
"$REPO/out/qemu-runtime/bin/zstd" -q -T0 -12 -o "$OUT/omarchy.raw.zst" "$W/image.raw"
(cd "$OUT" && split -b 1073741824 -a 1 omarchy.raw.zst omarchy.raw.zst.part- && shasum -a 256 omarchy.raw.zst.part-* omarchy.raw.zst > SHA256SUMS)
echo "$REVISION" > "$OUT/OMARCHY-REVISION"
say "Omarchy $REVISION: $OUT/omarchy.raw.zst ($(du -h "$OUT/omarchy.raw.zst" | cut -f1), $(ls "$OUT"/omarchy.raw.zst.part-* | wc -l | tr -d ' ') parts), SHA256SUMS $(sha "$OUT/SHA256SUMS")"
say "publish: gh release create omarchy-$REVISION --repo adminmylinux/mylinux-releases --latest=false $OUT/SHA256SUMS $OUT/omarchy.raw.zst.part-*"
