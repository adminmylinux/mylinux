#!/bin/sh
# Download the latest Debian stable cloud image for arm64 and the UEFI firmware that boots it, into out/debian (or
# $MYLINUX_OUT/debian; the Mac launcher app does this), for run-debian.sh: a terminal-only Debian server machine.
#  - the image: cloud.debian.org's "generic" build of the current stable release (the full kernel, so the 9p share and
#    the usual drivers are there), from the release's latest/ folder, checked against the SHA512SUMS beside it; the raw
#    disk inside the archive is kept sparse as debian.raw (about 300 MB to download, 1.3 GB kept)
#  - the firmware: QEMU's own edk2 UEFI build, pinned by checksum (tools/get-edk2.sh)
# Usage: tools/get-debian.sh            the latest image of the release below
#        tools/get-debian.sh --remove   delete the download (machines keep their own disks)
set -eu
cd "$(dirname "$0")/.."
RELEASE=trixie; RELEASE_ID=13
IMAGE="debian-$RELEASE_ID-generic-arm64"
# Debian publishes the cloud images from two hosts; cdimage sends the big file on to its mirror network. The first
# that answers both small files is used for everything (a timeout or an error 500 moves on to the next).
SOURCES="https://cdimage.debian.org/images/cloud/$RELEASE/latest https://cloud.debian.org/images/cloud/$RELEASE/latest"
FETCH="--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/debian"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST" "$DEST.prev"; echo "removed $DEST"; exit 0; fi
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Debian machine is for Apple-silicon Macs" >&2; exit 1; }
mkdir -p "$OUT"
STAGE="$OUT/.staging-debian"
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap 'rm -rf "$STAGE"' EXIT
echo "looking up the latest $RELEASE image ..."
BASE=""
for s in $SOURCES; do
  # shellcheck disable=SC2086
  if curl -fsSL $FETCH --max-time 60 -o "$STAGE/SHA512SUMS" "$s/SHA512SUMS" && curl -fsSL $FETCH --max-time 60 -o "$STAGE/$IMAGE.json" "$s/$IMAGE.json"; then
    BASE=$s; break
  fi
  echo "no answer from ${s%%/images*}; trying the next source ..."
done
[ -n "$BASE" ] || { echo "Debian's image servers are not answering right now (cdimage.debian.org, cloud.debian.org); try again in a few minutes" >&2; exit 1; }
VERSION=$(plutil -extract items.0.data.info.version raw -o - "$STAGE/$IMAGE.json" 2>/dev/null || true)
[ -n "$VERSION" ] || { echo "could not read the image version from $IMAGE.json" >&2; exit 1; }
REVISION="$RELEASE $VERSION"
if [ "$(cat "$DEST/DEBIAN-REVISION" 2>/dev/null)" = "$REVISION" ] && [ -s "$DEST/debian.raw" ] && [ -s "$DEST/edk2-aarch64-code.fd" ]; then
  echo "ok: $DEST already is Debian $REVISION"; exit 0
fi
echo "downloading Debian $REVISION ($IMAGE.tar.xz, about 300 MB) ..."
# shellcheck disable=SC2086
curl -fL $FETCH -C - --progress-bar -o "$STAGE/$IMAGE.tar.xz" "$BASE/$IMAGE.tar.xz"
(cd "$STAGE" && grep -E "  $IMAGE\.(tar\.xz|json)\$" SHA512SUMS | shasum -a 512 -c - >/dev/null) || { echo "the download does not match SHA512SUMS: nothing installed" >&2; exit 1; }
[ "$(grep -c -E "  $IMAGE\.tar\.xz\$" "$STAGE/SHA512SUMS")" = 1 ] || { echo "SHA512SUMS does not list $IMAGE.tar.xz: nothing installed" >&2; exit 1; }
sh tools/get-edk2.sh "$STAGE/new"
echo "unpacking ..."
# only the one disk file is expected in the archive
[ "$(tar -tJf "$STAGE/$IMAGE.tar.xz" | tr -d '\n')" = "disk.raw" ] || { echo "unexpected contents in $IMAGE.tar.xz: nothing installed" >&2; tar -tJf "$STAGE/$IMAGE.tar.xz" >&2; exit 1; }
mkdir -p "$STAGE/raw" && tar -xJf "$STAGE/$IMAGE.tar.xz" -C "$STAGE/raw"
# bsdtar writes the zero runs as holes already: the 3 GB disk takes about 1.3 GB
mv "$STAGE/raw/disk.raw" "$STAGE/new/debian.raw"
cp "$STAGE/$IMAGE.json" "$STAGE/new/image.json"
printf '%s\n' "$REVISION" > "$STAGE/new/DEBIAN-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
echo "ok: $DEST is Debian $REVISION (debian.raw, edk2-aarch64-code.fd). Start a machine with ./run-debian.sh"
