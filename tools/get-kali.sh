#!/bin/sh
# Download the Kali Linux (Xfce) guest, built by tools/build-kali-image.sh from Kali's own packages and published on
# github.com/adminmylinux/mylinux-releases, into out/kali (or $MYLINUX_OUT/kali; the Mac launcher app does this), for
# run-omarchy.sh with DESKTOP=kali. One pinned release: its SHA256SUMS must match the SHA-256 pinned here, and the
# kernel, initramfs and compressed root disk must match SHA256SUMS. A root disk above GitHub's 2 GB a file comes in
# parts (rootfs.ext4.zst.00, .01, ..., each in SHA256SUMS), put together here. About 2 GB to download.
# Usage: tools/get-kali.sh            the pinned release
#        tools/get-kali.sh --remove   delete the downloaded guest (machines keep their own disks)
#        tools/get-kali.sh --check    the saved and the pinned release (tools/download-cache.sh)
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
REPO=adminmylinux/mylinux-releases
TAG=kali-2026.10.07
SUMS_SHA256=6ca22bc08f93f7cb400836af9c29d07d2138dac1df738dd1929744982c4d0bc0
PINNED=$TAG
FILES="vmlinuz-linux initramfs-linux.img rootfs.ext4.zst"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/kali"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST"; echo "removed $DEST"; exit 0; fi
CACHED=$(cache_rev kali KALI-REVISION)
[ "${1:-}" = --check ] && { check_report "$CACHED" "$TAG"; exit 0; }
[ "${MYLINUX_FROM_CACHE:-0}" = 1 ] && [ -n "$CACHED" ] && TAG=$CACHED
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Kali Linux guest is for Apple-silicon Macs" >&2; exit 1; }
if [ "$(cat "$DEST/KALI-REVISION" 2>/dev/null)" = "$TAG" ] && [ -s "$DEST/rootfs.ext4.zst" ]; then
  echo "ok: $DEST already is Kali Linux $TAG"; exit 0
fi
mkdir -p "$OUT"
STAGE="$OUT/.staging-kali"
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap 'rm -rf "$STAGE"' EXIT
verify() {   # the three files against SHA256SUMS, which for the pinned release must be the pinned one (a saved one too)
  if [ "$TAG" = "$PINNED" ] && [ "$(shasum -a 256 "$1/SHA256SUMS" | cut -d' ' -f1)" != "$SUMS_SHA256" ]; then
    echo "SHA256SUMS of $TAG is not the one this launcher expects: nothing installed" >&2; return 1
  fi
  [ "$(grep -c -E '  (vmlinuz-linux|initramfs-linux.img|rootfs.ext4.zst)$' "$1/SHA256SUMS")" = 3 ] || { echo "the checksum list does not cover the guest files: nothing installed" >&2; return 1; }
  (cd "$1" && grep -E '  (vmlinuz-linux|initramfs-linux.img|rootfs.ext4.zst)$' SHA256SUMS | shasum -a 256 -c - >/dev/null) || { echo "the guest files do not match their checksums: nothing installed" >&2; return 1; }
}
if [ -n "$CACHED" ] && [ "$CACHED" = "$TAG" ]; then
  echo "installing Kali Linux $TAG from the saved download ..."
  cache_clone "$CACHE/kali" "$STAGE/new"
  verify "$STAGE/new" || exit 1
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
  echo "downloading Kali Linux $TAG (about 2 GB) ..."
  curl -fsSL --retry 3 --retry-delay 2 -o "$STAGE/new/SHA256SUMS" "$BASE/SHA256SUMS"
  # the list first: a release that is not the pinned one is refused before 2 GB come down
  if [ "$TAG" = "$PINNED" ] && [ "$(shasum -a 256 "$STAGE/new/SHA256SUMS" | cut -d' ' -f1)" != "$SUMS_SHA256" ]; then
    echo "SHA256SUMS of $TAG is not the one this launcher expects: nothing installed" >&2; exit 1
  fi
  # the root disk's parts, when the list names any (rootfs.ext4.zst.00, .01, ...), in their order
  PARTS=$(sed -n -E 's/^[0-9a-f]{64}  (rootfs\.ext4\.zst\.[0-9][0-9])$/\1/p' "$STAGE/new/SHA256SUMS" | sort)
  for f in $FILES; do
    if [ "$f" = rootfs.ext4.zst ] && [ -n "$PARTS" ]; then
      : > "$STAGE/new/$f"
      for part in $PARTS; do
        echo "downloading $part ..."
        curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/$part" "$BASE/$part"
        [ "$(shasum -a 256 "$STAGE/$part" | cut -d' ' -f1)" = "$(awk -v p="$part" '$2 == p { print $1 }' "$STAGE/new/SHA256SUMS")" ] || { echo "$part does not match its checksum: nothing installed" >&2; exit 1; }
        cat "$STAGE/$part" >> "$STAGE/new/$f"; rm -f "$STAGE/$part"
      done
    else
      echo "downloading $f ..."
      curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/new/$f" "$BASE/$f"
    fi
  done
  echo "checking the download ..."
  verify "$STAGE/new" || exit 1
fi
printf '%s\n' "$TAG" > "$STAGE/new/KALI-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
[ "$CACHED" = "$TAG" ] || cache_store kali "$DEST"
echo "ok: $DEST is Kali Linux $TAG. Start a machine with DESKTOP=kali ./run-omarchy.sh"
