#!/bin/sh
# Install the accelerated QEMU runtime into out/qemu-runtime (or $MYLINUX_OUT/qemu-runtime; the Mac launcher app
# does this). With it run.sh needs no Homebrew QEMU, and a guest whose Mesa has the virgl driver renders on the
# Mac's GPU. Usage: tools/get-qemu-runtime.sh [tag]      (default: the tag in tools/qemu-runtime.version)
#                   tools/get-qemu-runtime.sh --remove   back to Homebrew's QEMU
#        MYLINUX_RUNTIME_FILE=path/to/qemu-runtime-macos-arm64.tar.gz installs a local build (its .sha256 beside it)
# Downloaded into a staging directory, checksummed, unpacked and test-run there, and only then moved into place;
# a failed or interrupted download leaves the current runtime untouched.
set -eu
cd "$(dirname "$0")/.."
REPO=adminmylinux/mylinux
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/qemu-runtime"
NAME=qemu-runtime-macos-arm64.tar.gz
if [ "${1:-}" = --remove ]; then
  rm -rf "$DEST" "$DEST.prev"; echo "removed $DEST: machines start with Homebrew's QEMU again"; exit 0
fi
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the runtime is for Apple-silicon Macs" >&2; exit 1; }
TAG="${1:-$(cat tools/qemu-runtime.version)}"
mkdir -p "$OUT"
STAGE="$OUT/.staging-qemu-runtime"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
if [ -n "${MYLINUX_RUNTIME_FILE:-}" ]; then
  echo "installing $MYLINUX_RUNTIME_FILE ..."
  cp "$MYLINUX_RUNTIME_FILE" "$STAGE/$NAME"; cp "$MYLINUX_RUNTIME_FILE.sha256" "$STAGE/$NAME.sha256"
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
  for f in "$NAME.sha256" "$NAME"; do
    echo "downloading $f ($TAG) ..."
    curl -fL --progress-bar -o "$STAGE/$f" "$BASE/$f"
  done
fi
(cd "$STAGE" && shasum -a 256 -c "$NAME.sha256") || { echo "checksum mismatch: nothing replaced" >&2; exit 1; }
echo "unpacking ..."
# only the expected top-level folder, and nothing that points outside it
if tar -tzf "$STAGE/$NAME" | grep -v -E '^qemu-runtime(/|$)' | grep -q . || tar -tzf "$STAGE/$NAME" | grep -q -E '(^|/)\.\.(/|$)'; then
  echo "unexpected paths in the archive: nothing replaced" >&2; exit 1
fi
tar -xzf "$STAGE/$NAME" -C "$STAGE"
NEW="$STAGE/qemu-runtime"
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true
"$NEW/bin/qemu-system-aarch64" --version >/dev/null 2>&1 || { echo "the downloaded QEMU does not run on this Mac: nothing replaced" >&2; exit 1; }
"$NEW/bin/qemu-system-aarch64" -M virt -device help 2>/dev/null | grep -q virtio-gpu-gl-pci || { echo "the downloaded QEMU has no accelerated GPU device: nothing replaced" >&2; exit 1; }
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$NEW" "$DEST"
echo "ok: $DEST is $(cat "$DEST/RUNTIME-REVISION") ($("$DEST/bin/qemu-system-aarch64" --version | head -1)); the previous one is kept as qemu-runtime.prev"
