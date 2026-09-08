#!/bin/sh
# Download the prebuilt kernel + root filesystem of a myLinux release into out/ and verify the checksums.
# Usage: tools/get-image.sh [tag]     (default: the latest release)
set -e
cd "$(dirname "$0")/.."
REPO=adminmylinux/mylinux
TAG="${1:-latest}"
case "$TAG" in latest) BASE="https://github.com/$REPO/releases/latest/download" ;; *) BASE="https://github.com/$REPO/releases/download/$TAG" ;; esac
mkdir -p out
for f in SHA256SUMS Image rootfs.cpio.gz; do
  echo "downloading $f ..."
  curl -fL --progress-bar -o "out/$f" "$BASE/$f"
done
(cd out && shasum -a 256 -c SHA256SUMS)
echo "ok: out/Image and out/rootfs.cpio.gz are in place. Start with ./run.sh"
