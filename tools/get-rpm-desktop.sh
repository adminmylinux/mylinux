# Sourced by tools/get-fedora.sh, get-rocky.sh and get-centos.sh, which set KIND (fedora|rocky|centos), TITLE, and
# the pinned TAG and SUMS_SHA256: downloads that GNOME desktop, built by tools/build-rpm-image.sh and published on
# github.com/adminmylinux/mylinux-releases, into out/<KIND> (or $MYLINUX_OUT/<KIND>; the Mac launcher app does this),
# for run-omarchy.sh with DESKTOP=<KIND>. One pinned release: its SHA256SUMS must match the SHA-256 pinned there, and
# the kernel, initramfs and compressed root disk must match SHA256SUMS. 0.6 to 1.6 GB to download.
# Usage: tools/get-<kind>.sh            the pinned release
#        tools/get-<kind>.sh --remove   delete the downloaded guest (machines keep their own disks)
#        tools/get-<kind>.sh --check    the saved and the pinned release (tools/download-cache.sh)
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
REPO=adminmylinux/mylinux-releases
UPPER=$(echo "$KIND" | tr a-z A-Z)
PINNED=$TAG
FILES="vmlinuz-linux initramfs-linux.img rootfs.ext4.zst"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/$KIND"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST"; echo "removed $DEST"; exit 0; fi
CACHED=$(cache_rev "$KIND" "$UPPER-REVISION")
[ "${1:-}" = --check ] && { check_report "$CACHED" "$TAG"; exit 0; }
[ "${MYLINUX_FROM_CACHE:-0}" = 1 ] && [ -n "$CACHED" ] && TAG=$CACHED
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the $TITLE guest is for Apple-silicon Macs" >&2; exit 1; }
if [ "$(cat "$DEST/$UPPER-REVISION" 2>/dev/null)" = "$TAG" ] && [ -s "$DEST/rootfs.ext4.zst" ]; then
  echo "ok: $DEST already is $TITLE $TAG"; exit 0
fi
mkdir -p "$OUT"
STAGE="$OUT/.staging-$KIND"
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap 'rm -rf "$STAGE"' EXIT
verify() {   # the three files against SHA256SUMS, which for the pinned release must be the pinned one (a saved one too)
  if [ "$TAG" = "$PINNED" ] && [ "$(shasum -a 256 "$1/SHA256SUMS" | cut -d' ' -f1)" != "$SUMS_SHA256" ]; then
    echo "SHA256SUMS of $TAG is not the one this launcher expects: nothing installed" >&2; return 1
  fi
  [ "$(grep -c -E '  (vmlinuz-linux|initramfs-linux.img|rootfs.ext4.zst)$' "$1/SHA256SUMS")" = 3 ] || { echo "the checksum list does not cover the guest files: nothing installed" >&2; return 1; }
  (cd "$1" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "the guest files do not match their checksums: nothing installed" >&2; return 1; }
}
if [ -n "$CACHED" ] && [ "$CACHED" = "$TAG" ]; then
  echo "installing $TITLE $TAG from the saved download ..."
  rm -rf "$STAGE/new"; cache_clone "$CACHE/$KIND" "$STAGE/new"
  verify "$STAGE/new" || exit 1
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
  echo "downloading $TITLE $TAG ..."
  curl -fsSL --retry 3 --retry-delay 2 -o "$STAGE/new/SHA256SUMS" "$BASE/SHA256SUMS"
  # the list first: a release that is not the pinned one is refused before the rest comes down
  if [ "$TAG" = "$PINNED" ] && [ "$(shasum -a 256 "$STAGE/new/SHA256SUMS" | cut -d' ' -f1)" != "$SUMS_SHA256" ]; then
    echo "SHA256SUMS of $TAG is not the one this launcher expects: nothing installed" >&2; exit 1
  fi
  for f in $FILES; do
    echo "downloading $f ..."
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/new/$f" "$BASE/$f"
  done
  echo "checking the download ..."
  verify "$STAGE/new" || exit 1
fi
printf '%s\n' "$TAG" > "$STAGE/new/$UPPER-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
[ "$CACHED" = "$TAG" ] || cache_store "$KIND" "$DEST"
echo "ok: $DEST is $TITLE $TAG. Start a machine with DESKTOP=$KIND ./run-omarchy.sh"
