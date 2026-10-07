#!/bin/sh
# Keep the downloads that are installed in $MYLINUX_OUT as saved downloads in $MYLINUX_CACHE (tools/download-cache.sh),
# for the ones not saved yet at that revision: downloads from before saving existed, or from a checkout's scripts.
# The Mac launcher runs this at launch; APFS clones, so it takes no time and no extra space.
# Usage: MYLINUX_OUT=dir MYLINUX_CACHE=dir tools/save-downloads.sh
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
OUT="${MYLINUX_OUT:-out}"
[ -n "$CACHE" ] || { echo "MYLINUX_CACHE is not set: nothing to do"; exit 0; }

# save KIND REVISION-FILE DIR NEEDED [FILE...]: DIR's revision, when NEEDED is there and the saved one differs
save() {
  k=$1; rf=$2; d=$3; need=$4; shift 4
  rev=$(cat "$d/$rf" 2>/dev/null || true)
  [ -n "$rev" ] && [ -s "$d/$need" ] || return 0
  [ "$(cache_rev "$k" "$rf")" = "$rev" ] && return 0
  printf '%s %s: ' "$k" "$rev"
  cache_store "$k" "$d" "$@"
}

# the myLinux pair only when it is the release it says (a checkout's own build has no matching SHA256SUMS)
if [ -s "$OUT/SHA256SUMS" ] && (cd "$OUT" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
  save mylinux IMAGE-REVISION "$OUT" rootfs.cpio.gz SHA256SUMS Image rootfs.cpio.gz IMAGE-REVISION
fi
save omarchy OMARCHY-REVISION "$OUT/omarchy" rootfs.ext4.zst
save arch ARCH-REVISION "$OUT/arch" rootfs.ext4.zst
save debian DEBIAN-REVISION "$OUT/debian" debian.raw
save alpine ALPINE-REVISION "$OUT/alpine" alpine.raw
