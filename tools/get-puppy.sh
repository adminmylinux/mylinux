#!/bin/sh
# Download Puppy Linux (TrixiePup64, its own JWM desktop) into out/puppy (or $MYLINUX_OUT/puppy; the Mac launcher app
# does this), for run-omarchy.sh with DESKTOP=puppy. Puppy is a PC (x86-64) system, so it runs emulated, not at the
# Mac's own speed. The official ISO comes from the Puppy project's download server, must match the SHA-256 pinned
# here, and is unpacked: the kernel, the initrd and the .sfs files Puppy is made of. The ISO itself is not kept.
# About 1 GB to download.
# Usage: tools/get-puppy.sh            the pinned release
#        tools/get-puppy.sh --remove   delete the downloaded guest (machines keep their own disks)
#        tools/get-puppy.sh --check    the saved and the pinned release (tools/download-cache.sh)
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
TAG=trixiepup64-legacy-11.4
ISO=Trixiepup64_Legacy-11.4.iso
URL="https://distro.ibiblio.org/puppylinux/puppy-trixie/TrixiePup64/11.4/legacy/$ISO"
ISO_SHA256=7f4ccc40d407bfa5fd8d63d636a035cad1b20bf55b982b3f7518bcc57ba82a7f
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/puppy"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST"; echo "removed $DEST"; exit 0; fi
CACHED=$(cache_rev puppy PUPPY-REVISION)
[ "${1:-}" = --check ] && { check_report "$CACHED" "$TAG"; exit 0; }
[ "${MYLINUX_FROM_CACHE:-0}" = 1 ] && [ -n "$CACHED" ] && TAG=$CACHED
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Puppy Linux guest is for Apple-silicon Macs" >&2; exit 1; }
# what a machine is made from: the kernel and initrd (under the names the other desktops use) and Puppy's layers
complete() { [ -s "$1/vmlinuz-linux" ] && [ -s "$1/initramfs-linux.img" ] && ls "$1"/puppy_*.sfs >/dev/null 2>&1; }
if [ "$(cat "$DEST/PUPPY-REVISION" 2>/dev/null)" = "$TAG" ] && complete "$DEST"; then
  echo "ok: $DEST already is Puppy Linux $TAG"; exit 0
fi
mkdir -p "$OUT"
STAGE="$OUT/.staging-puppy"
rm -rf "$STAGE"; mkdir -p "$STAGE/new" "$STAGE/iso"; trap 'rm -rf "$STAGE"' EXIT
if [ -n "$CACHED" ] && [ "$CACHED" = "$TAG" ]; then
  echo "installing Puppy Linux $TAG from the saved download ..."
  rmdir "$STAGE/new"; cache_clone "$CACHE/puppy" "$STAGE/new"
  (cd "$STAGE/new" && shasum -a 256 -c SHA256SUMS >/dev/null) && complete "$STAGE/new" || { echo "the saved download does not match its checksums: nothing installed" >&2; exit 1; }
else
  echo "downloading Puppy Linux $TAG (about 1 GB) ..."
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$STAGE/$ISO" "$URL"
  echo "checking the download ..."
  [ "$(shasum -a 256 "$STAGE/$ISO" | cut -d' ' -f1)" = "$ISO_SHA256" ] || { echo "$ISO is not the one this launcher expects: nothing installed" >&2; exit 1; }
  echo "unpacking ..."
  # macOS's tar reads ISO images; only the files a machine boots with leave the staging folder
  tar -xf "$STAGE/$ISO" -C "$STAGE/iso" vmlinuz initrd.gz '*.sfs' || { echo "could not unpack $ISO: nothing installed" >&2; exit 1; }
  rm -f "$STAGE/$ISO"
  mv "$STAGE/iso/vmlinuz" "$STAGE/new/vmlinuz-linux"; mv "$STAGE/iso/initrd.gz" "$STAGE/new/initramfs-linux.img"
  for f in "$STAGE"/iso/*.sfs; do case "$(basename "$f")" in *[!A-Za-z0-9._-]*) echo "unexpected file name in $ISO: nothing installed" >&2; exit 1 ;; esac; mv "$f" "$STAGE/new/"; done
  complete "$STAGE/new" || { echo "$ISO does not hold Puppy's kernel and layers: nothing installed" >&2; exit 1; }
  # for a later install from the saved download: the unpacked files' own checksums (the ISO's is the pinned one)
  (cd "$STAGE/new" && shasum -a 256 vmlinuz-linux initramfs-linux.img ./*.sfs > SHA256SUMS)
fi
printf '%s\n' "$TAG" > "$STAGE/new/PUPPY-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
[ "$CACHED" = "$TAG" ] || cache_store puppy "$DEST"
echo "ok: $DEST is Puppy Linux $TAG. Start a machine with DESKTOP=puppy ./run-omarchy.sh"
