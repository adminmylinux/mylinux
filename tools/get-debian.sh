#!/bin/sh
# Download the latest Debian stable cloud image for arm64 and the UEFI firmware that boots it, into out/debian (or
# $MYLINUX_OUT/debian; the Mac launcher app does this), for run-debian.sh: a terminal-only Debian server machine.
#  - the image: cloud.debian.org's "generic" build of the current stable release (the full kernel, so the 9p share and
#    the usual drivers are there), from the release's latest/ folder, checked against the SHA512SUMS beside it; the raw
#    disk inside the archive is kept sparse as debian.raw (about 300 MB to download, 1.3 GB kept)
#  - the firmware: the edk2 UEFI build that QEMU itself ships (pc-bios/edk2-aarch64-code.fd.bz2, BSD-2-Clause-Patent
#    with its licence file), from the QEMU commit the runtime is built from, pinned by checksum; the runtime carries no
#    firmware of its own. Read-only flash for the guest; nothing from it runs on the Mac. (Debian's own AAVMF build
#    stops after its banner on QEMU 11 under HVF, so it is not used.)
# Usage: tools/get-debian.sh            the latest image of the release below
#        tools/get-debian.sh --remove   delete the download (machines keep their own disks)
set -eu
cd "$(dirname "$0")/.."
RELEASE=trixie; RELEASE_ID=13
IMAGE="debian-$RELEASE_ID-generic-arm64"
BASE="https://cloud.debian.org/images/cloud/$RELEASE/latest"
QEMU_COMMIT=c3d48b7d1e89604920e5b81b91140c2ad39a1943      # the runtime's QEMU (tools/build-qemu-runtime.sh)
EFI_URL="https://gitlab.com/qemu-project/qemu/-/raw/$QEMU_COMMIT/pc-bios/edk2-aarch64-code.fd.bz2"
EFI_SHA256=c023444108b7a132fdebf70c4765cd2dd9af2a9ff7d001a743aaabe87c20a458
EFI_LICENSE_URL="https://gitlab.com/qemu-project/qemu/-/raw/$QEMU_COMMIT/pc-bios/edk2-licenses.txt"
EFI_LICENSE_SHA256=1ddeaed2e7d2e9ecb960bdfc1b8ee45387aff70d056d985d145949af3951657c
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/debian"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST" "$DEST.prev"; echo "removed $DEST"; exit 0; fi
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Debian machine is for Apple-silicon Macs" >&2; exit 1; }
mkdir -p "$OUT"
STAGE="$OUT/.staging-debian"
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap 'rm -rf "$STAGE"' EXIT
echo "looking up the latest $RELEASE image ..."
curl -fsSL --retry 3 --retry-delay 2 -o "$STAGE/SHA512SUMS" "$BASE/SHA512SUMS"
curl -fsSL --retry 3 --retry-delay 2 -o "$STAGE/$IMAGE.json" "$BASE/$IMAGE.json"
VERSION=$(plutil -extract items.0.data.info.version raw -o - "$STAGE/$IMAGE.json" 2>/dev/null || true)
[ -n "$VERSION" ] || { echo "could not read the image version from $IMAGE.json" >&2; exit 1; }
REVISION="$RELEASE $VERSION"
if [ "$(cat "$DEST/DEBIAN-REVISION" 2>/dev/null)" = "$REVISION" ] && [ -s "$DEST/debian.raw" ] && [ -s "$DEST/edk2-aarch64-code.fd" ]; then
  echo "ok: $DEST already is Debian $REVISION"; exit 0
fi
echo "downloading Debian $REVISION ($IMAGE.tar.xz, about 300 MB) ..."
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/$IMAGE.tar.xz" "$BASE/$IMAGE.tar.xz"
(cd "$STAGE" && grep -E "  $IMAGE\.(tar\.xz|json)\$" SHA512SUMS | shasum -a 512 -c - >/dev/null) || { echo "the download does not match SHA512SUMS: nothing installed" >&2; exit 1; }
[ "$(grep -c -E "  $IMAGE\.tar\.xz\$" "$STAGE/SHA512SUMS")" = 1 ] || { echo "SHA512SUMS does not list $IMAGE.tar.xz: nothing installed" >&2; exit 1; }
echo "downloading the UEFI firmware (QEMU's edk2 build) ..."
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/edk2.fd.bz2" "$EFI_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$STAGE/edk2-licenses.txt" "$EFI_LICENSE_URL"
[ "$(shasum -a 256 "$STAGE/edk2.fd.bz2" | cut -d' ' -f1)" = "$EFI_SHA256" ] || { echo "the firmware does not match its pinned checksum: nothing installed" >&2; exit 1; }
[ "$(shasum -a 256 "$STAGE/edk2-licenses.txt" | cut -d' ' -f1)" = "$EFI_LICENSE_SHA256" ] || { echo "the firmware licence file does not match its pinned checksum: nothing installed" >&2; exit 1; }
echo "unpacking ..."
# only the one disk file is expected in the archive
[ "$(tar -tJf "$STAGE/$IMAGE.tar.xz" | tr -d '\n')" = "disk.raw" ] || { echo "unexpected contents in $IMAGE.tar.xz: nothing installed" >&2; tar -tJf "$STAGE/$IMAGE.tar.xz" >&2; exit 1; }
mkdir -p "$STAGE/raw" && tar -xJf "$STAGE/$IMAGE.tar.xz" -C "$STAGE/raw"
# bsdtar writes the zero runs as holes already: the 3 GB disk takes about 1.3 GB
mv "$STAGE/raw/disk.raw" "$STAGE/new/debian.raw"
bunzip2 -c "$STAGE/edk2.fd.bz2" > "$STAGE/new/edk2-aarch64-code.fd"
cp "$STAGE/edk2-licenses.txt" "$STAGE/new/edk2-licenses.txt"
cp "$STAGE/$IMAGE.json" "$STAGE/new/image.json"
[ "$(stat -f %z "$STAGE/new/edk2-aarch64-code.fd")" = 67108864 ] || { echo "the firmware is not a 64 MiB flash image: nothing installed" >&2; exit 1; }
printf '%s\n' "$REVISION" > "$STAGE/new/DEBIAN-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
echo "ok: $DEST is Debian $REVISION (debian.raw, edk2-aarch64-code.fd). Start a machine with ./run-debian.sh"
