#!/bin/sh
# Download the Omarchy guest into out/omarchy (or $MYLINUX_OUT/omarchy; the Mac launcher app does this), for
# run-omarchy.sh: Omarchy installed from its own signed release ISO for aarch64, with Try Omarchy's guest package for
# the Mac integration (tools/build-omarchy-image.sh builds it), published on github.com/adminmylinux/mylinux-releases.
# One pinned release: its SHA256SUMS must match the SHA-256 pinned here, and every part of the compressed disk, and
# the disk they make together, must match SHA256SUMS. Then QEMU's own UEFI firmware (tools/get-edk2.sh), which the disk
# boots through. About 3.7 GB to download. Machines made before 0.8.7 (Try Omarchy's guest) keep their own disks and
# kernels and need none of this.
# Usage: tools/get-omarchy.sh            the pinned release
#        tools/get-omarchy.sh --remove   delete the downloaded guest (machines keep their own disks)
#        tools/get-omarchy.sh --check    the saved and the pinned release (tools/download-cache.sh)
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
REPO=adminmylinux/mylinux-releases
TAG=omarchy-4.5.0-1
SUMS_SHA256=6cc92b6c92c149e0f0c0fc9f0ead8d96ee5149c326babd01cd0b0fa33bc16aea
PINNED=$TAG
PARTS="omarchy.raw.zst.part-a omarchy.raw.zst.part-b omarchy.raw.zst.part-c omarchy.raw.zst.part-d"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/omarchy"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST"; echo "removed $DEST"; exit 0; fi
CACHED=$(cache_rev omarchy OMARCHY-REVISION)
[ "${1:-}" = --check ] && { check_report "$CACHED" "$TAG"; exit 0; }
[ "${MYLINUX_FROM_CACHE:-0}" = 1 ] && [ -n "$CACHED" ] && TAG=$CACHED
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Omarchy guest is for Apple-silicon Macs" >&2; exit 1; }
if [ "$(cat "$DEST/OMARCHY-REVISION" 2>/dev/null)" = "$TAG" ] && [ -s "$DEST/omarchy.raw.zst" ] && [ -s "$DEST/edk2-aarch64-code.fd" ]; then
  echo "ok: $DEST already is Omarchy $TAG"; exit 0
fi
mkdir -p "$OUT"
STAGE="$OUT/.staging-omarchy"
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap 'rm -rf "$STAGE"' EXIT
pinned_list() {   # the pinned release's list is the one this launcher expects (a saved one too)
  [ "$TAG" != "$PINNED" ] || [ "$(shasum -a 256 "$1/SHA256SUMS" | cut -d' ' -f1)" = "$SUMS_SHA256" ] || {
    echo "SHA256SUMS of $TAG is not the one this launcher expects: nothing installed" >&2; return 1; }
}
whole() {         # the disk the parts make, against its line in SHA256SUMS
  grep -q '  omarchy.raw.zst$' "$1/SHA256SUMS" || { echo "the checksum list does not cover the disk: nothing installed" >&2; return 1; }
  (cd "$1" && grep '  omarchy.raw.zst$' SHA256SUMS | shasum -a 256 -c - >/dev/null) || { echo "the disk does not match its checksum: nothing installed" >&2; return 1; }
}
if [ -n "$CACHED" ] && [ "$CACHED" = "$TAG" ]; then
  echo "installing Omarchy $TAG from the saved download ..."
  rm -rf "$STAGE/new"; cache_clone "$CACHE/omarchy" "$STAGE/new"
  pinned_list "$STAGE/new" && whole "$STAGE/new" || exit 1
  [ -s "$STAGE/new/edk2-aarch64-code.fd" ] || sh tools/get-edk2.sh "$STAGE/new"
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
  echo "downloading Omarchy $TAG (about 3.7 GB) ..."
  curl -fsSL --retry 3 --retry-delay 2 -o "$STAGE/new/SHA256SUMS" "$BASE/SHA256SUMS"
  # the list first: a release that is not the pinned one is refused before 3.7 GB come down
  pinned_list "$STAGE/new" || exit 1
  for f in $PARTS; do
    grep -q "  $f\$" "$STAGE/new/SHA256SUMS" || { echo "the checksum list does not cover $f: nothing installed" >&2; exit 1; }
    echo "downloading $f ..."
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/new/$f" "$BASE/$f"
    (cd "$STAGE/new" && grep "  $f\$" SHA256SUMS | shasum -a 256 -c - >/dev/null) || { echo "$f does not match its checksum: nothing installed" >&2; exit 1; }
  done
  echo "checking the download ..."
  (cd "$STAGE/new" && cat $PARTS > omarchy.raw.zst && rm -f $PARTS)
  whole "$STAGE/new" || exit 1
  [ -s "$DEST/edk2-aarch64-code.fd" ] && cp "$DEST/edk2-aarch64-code.fd" "$DEST/edk2-licenses.txt" "$STAGE/new/" 2>/dev/null \
    || sh tools/get-edk2.sh "$STAGE/new"
fi
printf '%s\n' "$TAG" > "$STAGE/new/OMARCHY-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
[ "$CACHED" = "$TAG" ] || cache_store omarchy "$DEST"
echo "ok: $DEST is Omarchy $TAG. Start a machine with ./run-omarchy.sh"
