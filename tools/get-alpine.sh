#!/bin/sh
# Download the latest Alpine Linux cloud image for aarch64 and the UEFI firmware that boots it, into out/alpine (or
# $MYLINUX_OUT/alpine; the Mac launcher app does this), for run-alpine.sh: a small terminal-only server machine.
#  - the image: alpinelinux.org's cloud-init build of the newest stable release ("cloudinit", the virt kernel with
#    the 9p share and virtio drivers, set up by cloud-init from the launcher's NoCloud seed), found in the release
#    folder's listing and checked against the .sha512 beside it; the raw disk inside the archive is kept sparse as
#    alpine.raw (about 100 MB to download, 1 GB disk)
#  - the firmware: QEMU's own edk2 UEFI build, pinned by checksum (tools/get-edk2.sh)
# Usage: tools/get-alpine.sh            the latest image
#        tools/get-alpine.sh --remove   delete the download (machines keep their own disks)
set -eu
cd "$(dirname "$0")/.."
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud"
FETCH="--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/alpine"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST" "$DEST.prev"; echo "removed $DEST"; exit 0; fi
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Alpine machine is for Apple-silicon Macs" >&2; exit 1; }
mkdir -p "$OUT"
STAGE="$OUT/.staging-alpine"
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap 'rm -rf "$STAGE"' EXIT
echo "looking up the latest Alpine image ..."
# shellcheck disable=SC2086
curl -fsSL $FETCH --max-time 60 -o "$STAGE/listing.html" "$BASE/" \
  || { echo "Alpine's download server is not answering right now (dl-cdn.alpinelinux.org); try again in a few minutes" >&2; exit 1; }
# alpine-3.24.2-aarch64-cloudinit-r0.raw.tar.gz: the highest release, then the highest image revision
IMAGE=$(grep -oE 'alpine-[0-9]+\.[0-9]+\.[0-9]+-aarch64-cloudinit-r[0-9]+\.raw\.tar\.gz' "$STAGE/listing.html" | sort -u \
  | sed -E 's/^alpine-([0-9]+)\.([0-9]+)\.([0-9]+)-aarch64-cloudinit-r([0-9]+)\.raw\.tar\.gz$/\1 \2 \3 \4 &/' \
  | sort -n -k1,1 -k2,2 -k3,3 -k4,4 | tail -1 | cut -d' ' -f5)
[ -n "$IMAGE" ] || { echo "no aarch64 cloud-init image in $BASE/" >&2; exit 1; }
REVISION=$(printf '%s' "$IMAGE" | sed -E 's/^alpine-(.*)-aarch64-cloudinit-(r[0-9]+)\.raw\.tar\.gz$/\1 \2/')
if [ "$(cat "$DEST/ALPINE-REVISION" 2>/dev/null)" = "$REVISION" ] && [ -s "$DEST/alpine.raw" ] && [ -s "$DEST/edk2-aarch64-code.fd" ]; then
  echo "ok: $DEST already is Alpine $REVISION"; exit 0
fi
echo "downloading Alpine $REVISION ($IMAGE, about 100 MB) ..."
# shellcheck disable=SC2086
curl -fsSL $FETCH --max-time 60 -o "$STAGE/$IMAGE.sha512" "$BASE/$IMAGE.sha512"
# shellcheck disable=SC2086
curl -fL $FETCH -C - --progress-bar -o "$STAGE/$IMAGE" "$BASE/$IMAGE"
WANT=$(cut -d' ' -f1 < "$STAGE/$IMAGE.sha512" | tr -d '\n')
[ ${#WANT} = 128 ] || { echo "$IMAGE.sha512 is not a SHA-512 checksum: nothing installed" >&2; exit 1; }
[ "$(shasum -a 512 "$STAGE/$IMAGE" | cut -d' ' -f1)" = "$WANT" ] || { echo "the download does not match $IMAGE.sha512: nothing installed" >&2; exit 1; }
sh tools/get-edk2.sh "$STAGE/new"
echo "unpacking ..."
# only the one disk file is expected in the archive
[ "$(tar -tzf "$STAGE/$IMAGE" | tr -d '\n')" = "disk.raw" ] || { echo "unexpected contents in $IMAGE: nothing installed" >&2; tar -tzf "$STAGE/$IMAGE" >&2; exit 1; }
mkdir -p "$STAGE/raw" && tar -xzf "$STAGE/$IMAGE" -C "$STAGE/raw"
# the zero runs become holes: the 1 GB disk takes about 250 MB
dd if="$STAGE/raw/disk.raw" of="$STAGE/new/alpine.raw" bs=1m conv=sparse 2>/dev/null || { echo "could not unpack the disk: nothing installed" >&2; exit 1; }
# a hole at the very end leaves the copy short: set its length to the disk's
SIZE=$(stat -f %z "$STAGE/raw/disk.raw"); dd if=/dev/zero of="$STAGE/new/alpine.raw" bs=1 count=0 seek="$SIZE" 2>/dev/null
cmp -s "$STAGE/raw/disk.raw" "$STAGE/new/alpine.raw" || { echo "the unpacked disk differs from the download: nothing installed" >&2; exit 1; }
# Limine waits 10 s at every boot for a menu choice a server never makes. Its config sits in the FAT boot partition;
# "timeout: 10\n" and "timeout: 0\n\n" are the same length, so the file changes in place with its size and the
# filesystem untouched. Only when it is found once, as the config's first line (run-server.sh also sets it on the
# first boot, so an image laid out differently just keeps the wait once).
HITS=$(LC_ALL=C grep -obUa 'timeout: 10' "$STAGE/new/alpine.raw" | cut -d: -f1)
if [ "$(printf '%s\n' "$HITS" | grep -c .)" = 1 ] && [ "$(dd if="$STAGE/new/alpine.raw" bs=1 skip="$HITS" count=24 2>/dev/null | LC_ALL=C tr '\n' '|')" = "timeout: 10|serial: yes|" ]; then
  printf 'timeout: 0\n\n' | dd of="$STAGE/new/alpine.raw" bs=1 seek="$HITS" conv=notrunc 2>/dev/null && echo "the boot menu's countdown is off"
fi
printf '%s\n' "$REVISION" > "$STAGE/new/ALPINE-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
echo "ok: $DEST is Alpine $REVISION (alpine.raw, edk2-aarch64-code.fd). Start a machine with ./run-alpine.sh"
