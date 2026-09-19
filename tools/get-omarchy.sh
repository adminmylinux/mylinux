#!/bin/sh
# Download the Omarchy guest (ARM64 Arch Linux with Omarchy, built and published by the Try Omarchy project,
# https://github.com/omacom/try-omarchy) into out/omarchy (or $MYLINUX_OUT/omarchy; the Mac launcher app does this),
# for run-omarchy.sh. The guest only exists inside that project's signed release disk image, so this downloads the
# image of one pinned release, checks it against the pinned SHA-256, checks the app's signature and team, copies out
# the kernel, initramfs and compressed root disk, and checks those against the checksums that ship beside them.
# Nothing from the disk image is run. About 1.4 GB to download, 1.5 GB kept.
# Usage: tools/get-omarchy.sh            the pinned release
#        tools/get-omarchy.sh --remove   delete the downloaded guest (machines keep their own disks)
#        MYLINUX_OMARCHY_DMG=path/TryOmarchy.dmg uses a disk image that is already here (same checks)
set -eu
cd "$(dirname "$0")/.."
TAG=v0.4.1
DMG_SHA256=e2f172f67e5d8a99df8e46fa6f7814a061c0af249f100a6bdc7836b922f47674
TEAM=RZC79MPD34
URL="https://github.com/omacom/try-omarchy/releases/download/$TAG/TryOmarchy.dmg"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/omarchy"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST"; echo "removed $DEST"; exit 0; fi
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Omarchy guest is for Apple-silicon Macs" >&2; exit 1; }
if [ "$(cat "$DEST/OMARCHY-REVISION" 2>/dev/null)" = "$TAG" ] && [ -s "$DEST/rootfs.ext4.zst" ]; then
  echo "ok: $DEST already is Try Omarchy $TAG"; exit 0
fi
mkdir -p "$OUT"
STAGE="$OUT/.staging-omarchy"
MNT="$STAGE/mnt"
cleanup() { [ -d "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$STAGE"; }
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap cleanup EXIT
if [ -n "${MYLINUX_OMARCHY_DMG:-}" ]; then
  DMG="$MYLINUX_OMARCHY_DMG"; echo "using $DMG ..."
else
  DMG="$STAGE/TryOmarchy.dmg"
  echo "downloading Try Omarchy $TAG (1.4 GB) ..."
  curl -fL --progress-bar -o "$DMG" "$URL"
fi
echo "checking the download ..."
[ "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" = "$DMG_SHA256" ] || { echo "the disk image is not Try Omarchy $TAG (checksum mismatch): nothing installed" >&2; exit 1; }
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null || { echo "could not open the disk image" >&2; exit 1; }
APP="$MNT/Try Omarchy.app"
codesign --verify --deep --strict "$APP" 2>/dev/null || { echo "the app inside the disk image has a broken signature: nothing installed" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "^TeamIdentifier=$TEAM\$" || { echo "the app inside the disk image is not signed by the Try Omarchy team: nothing installed" >&2; exit 1; }
G="$APP/Contents/Resources/guest"
echo "copying the guest ..."
for f in vmlinuz-linux initramfs-linux.img rootfs.ext4.zst SHA256SUMS guest-manifest.json; do
  [ -f "$G/$f" ] || { echo "the disk image has no guest/$f: nothing installed" >&2; exit 1; }
  cp "$G/$f" "$STAGE/new/$f"
done
for f in "$APP/Contents/Resources/"*NOTICE* "$APP/Contents/Resources/"*LICENSE* "$G/"*licenses* "$G/"*provenance*; do [ -f "$f" ] && cp "$f" "$STAGE/new/" || true; done
(cd "$STAGE/new" && grep -E '  (vmlinuz-linux|initramfs-linux.img|rootfs.ext4.zst)$' SHA256SUMS | shasum -a 256 -c - >/dev/null) || { echo "the guest files do not match their checksums: nothing installed" >&2; exit 1; }
[ "$(grep -c -E '  (vmlinuz-linux|initramfs-linux.img|rootfs.ext4.zst)$' "$STAGE/new/SHA256SUMS")" = 3 ] || { echo "the checksum list does not cover the guest files: nothing installed" >&2; exit 1; }
hdiutil detach "$MNT" -quiet || true
printf '%s\n' "$TAG" > "$STAGE/new/OMARCHY-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
echo "ok: $DEST is Try Omarchy $TAG. Start a machine with ./run-omarchy.sh"
