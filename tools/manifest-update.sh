#!/bin/sh
# Refresh board/overlay/usr/share/mylinux/manifest.env: resolve the current Debian trixie arm64 rootfs commit
# and the latest Codex release, download both, hash them and rewrite the manifest. Review the diff, then
# commit. Usage: tools/manifest-update.sh [--codex-tag rust-vX.Y.Z]
set -eu
cd "$(dirname "$0")/.."
M=board/overlay/usr/share/mylinux/manifest.env
T=$(mktemp -d "${TMPDIR:-/tmp}/manifest.XXXXXX"); trap 'rm -rf "$T"' EXIT
TAG=""; [ "${1:-}" = --codex-tag ] && TAG="$2"
echo "Debian rootfs: resolving dist-arm64v8 ..."
SHA=$(git ls-remote https://github.com/debuerreotype/docker-debian-artifacts refs/heads/dist-arm64v8 | cut -f1)
[ -n "$SHA" ] || { echo "could not resolve the branch" >&2; exit 1; }
RURL="https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/$SHA/trixie/oci/blobs/rootfs.tar.gz"
curl -fsSL -o "$T/rootfs.tar.gz" "$RURL"
RSUM=$(shasum -a 256 "$T/rootfs.tar.gz" | cut -d' ' -f1)
VER=$(curl -fsSL "https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/$SHA/trixie/rootfs.debian_version" || echo "?")
EPOCH=$(curl -fsSL "https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/$SHA/trixie/rootfs.debuerreotype-epoch" || echo "?")
echo "Codex: resolving release ..."
if [ -z "$TAG" ]; then
  TAG=$(curl -fsSL -H 'Accept: application/vnd.github+json' https://api.github.com/repos/openai/codex/releases/latest | sed -n 's/^  "tag_name": "\(.*\)",$/\1/p')
fi
[ -n "$TAG" ] || { echo "could not resolve the Codex release tag" >&2; exit 1; }
CURL="https://github.com/openai/codex/releases/download/$TAG/codex-aarch64-unknown-linux-musl.tar.gz"
curl -fsSL -o "$T/codex.tgz" "$CURL"
CSUM=$(shasum -a 256 "$T/codex.tgz" | cut -d' ' -f1)
sed -i.bak \
  -e "s|^DEBIAN_ROOTFS_URL=.*|DEBIAN_ROOTFS_URL=$RURL|" \
  -e "s|^DEBIAN_ROOTFS_SHA256=.*|DEBIAN_ROOTFS_SHA256=$RSUM|" \
  -e "s|^DEBIAN_ROOTFS_NOTE=.*|DEBIAN_ROOTFS_NOTE=\"Debian $VER (debuerreotype epoch $EPOCH)\"|" \
  -e "s|^CODEX_VERSION=.*|CODEX_VERSION=$TAG|" \
  -e "s|^CODEX_URL=.*|CODEX_URL=$CURL|" \
  -e "s|^CODEX_SHA256=.*|CODEX_SHA256=$CSUM|" "$M"
rm -f "$M.bak"
git --no-pager diff --stat -- "$M"
echo "manifest updated: Debian $VER ($SHA), Codex $TAG"
