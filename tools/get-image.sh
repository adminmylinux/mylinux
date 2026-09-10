#!/bin/sh
# Download the prebuilt kernel + root filesystem of a myLinux release into out/ and verify the checksums.
# Usage: tools/get-image.sh [tag]     (default: the latest release)
# One release is resolved first (so the three files always belong together), everything is downloaded
# into a staging directory and verified there, and only then promoted as a pair; the previous pair is
# kept as out/*.prev. An interrupted or failed download leaves the current images untouched.
set -eu
cd "$(dirname "$0")/.."
REPO=adminmylinux/mylinux
TAG="${1:-latest}"
if [ "$TAG" = latest ]; then
  # the redirect target of /releases/latest names the tag; no API token needed
  TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's#.*/tag/##')
  [ -n "$TAG" ] || { echo "could not resolve the latest release" >&2; exit 1; }
fi
BASE="https://github.com/$REPO/releases/download/$TAG"
STAGE="out/.staging-$TAG"
mkdir -p out "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
for f in SHA256SUMS Image rootfs.cpio.gz; do
  echo "downloading $f ($TAG) ..."
  curl -fL --progress-bar -o "$STAGE/$f" "$BASE/$f"
done
(cd "$STAGE" && shasum -a 256 -c SHA256SUMS) || { echo "checksum mismatch: nothing replaced" >&2; exit 1; }
for f in Image rootfs.cpio.gz; do [ -f "out/$f" ] && mv -f "out/$f" "out/$f.prev"; done
for f in Image rootfs.cpio.gz SHA256SUMS; do mv -f "$STAGE/$f" "out/$f"; done
echo "$TAG" > out/IMAGE-REVISION
echo "ok: out/Image and out/rootfs.cpio.gz are release $TAG (previous pair kept as out/*.prev). Start with ./run.sh"
