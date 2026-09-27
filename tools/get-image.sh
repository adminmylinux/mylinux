#!/bin/sh
# Download the prebuilt kernel + root filesystem of a myLinux release (github.com/adminmylinux/mylinux-releases) into
# out/ and verify the checksums.
# Usage: tools/get-image.sh [tag]     (default: the latest release)
#        tools/get-image.sh --check   the saved and the latest release (tools/download-cache.sh)
#        MYLINUX_OUT=dir tools/get-image.sh   downloads into dir instead of out/ (the Mac launcher app does this)
# One release is resolved first (so the three files always belong together), everything is downloaded
# into a staging directory and verified there, and only then promoted as a pair; the previous pair is
# kept as out/*.prev. An interrupted or failed download leaves the current images untouched.
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
REPO=adminmylinux/mylinux-releases      # release assets only; the source repository is private
CHECK=0; [ "${1:-}" = --check ] && { CHECK=1; shift; }
TAG="${1:-latest}"
CACHED=$(cache_rev mylinux IMAGE-REVISION)
if [ "${MYLINUX_FROM_CACHE:-0}" = 1 ] && [ -n "$CACHED" ]; then
  TAG=$CACHED
elif [ "$TAG" = latest ]; then
  # the redirect target of /releases/latest names the tag; no API token needed
  TAG=$(curl -fsSIL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's#.*/tag/##') || TAG=""
  case "$TAG" in http*|"") TAG="" ;; esac
  if [ -z "$TAG" ]; then
    [ "$CHECK" = 1 ] && { check_report "$CACHED" ""; exit 0; }
    [ -n "$CACHED" ] || { echo "could not resolve the latest release" >&2; exit 1; }
    echo "could not look up the latest release; installing the saved $CACHED"
    TAG=$CACHED
  fi
fi
[ "$CHECK" = 1 ] && { check_report "$CACHED" "$TAG"; exit 0; }
BASE="https://github.com/$REPO/releases/download/$TAG"
OUT="${MYLINUX_OUT:-out}"
STAGE="$OUT/.staging-$TAG"
mkdir -p "$OUT" "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
SAVED=0
if [ -n "$CACHED" ] && [ "$TAG" = "$CACHED" ]; then
  echo "installing myLinux $TAG from the saved download ..."
  for f in SHA256SUMS Image rootfs.cpio.gz; do cache_clone "$CACHE/mylinux/$f" "$STAGE/$f"; done
  SAVED=1
else
  for f in SHA256SUMS Image rootfs.cpio.gz; do
    echo "downloading $f ($TAG) ..."
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/$f" "$BASE/$f"
  done
fi
(cd "$STAGE" && shasum -a 256 -c SHA256SUMS) || { echo "checksum mismatch: nothing replaced" >&2; exit 1; }
for f in Image rootfs.cpio.gz; do [ -f "$OUT/$f" ] && mv -f "$OUT/$f" "$OUT/$f.prev"; done
for f in Image rootfs.cpio.gz SHA256SUMS; do mv -f "$STAGE/$f" "$OUT/$f"; done
echo "$TAG" > "$OUT/IMAGE-REVISION"
[ "$SAVED" = 1 ] || cache_store mylinux "$OUT" SHA256SUMS Image rootfs.cpio.gz IMAGE-REVISION
echo "ok: $OUT/Image and $OUT/rootfs.cpio.gz are release $TAG (previous pair kept as *.prev). Start with ./run.sh"
