#!/bin/sh
# Download what a Tiny Alpine machine is made of into out/tiny (or $MYLINUX_OUT/tiny; the Mac launcher app does
# this), for run-tiny.sh: Alpine Linux at its smallest, a terminal-only server machine that starts in a second.
#  - Alpine's mini root filesystem for aarch64 (about 4 MB: BusyBox, musl and apk), the newest stable release in
#    alpinelinux.org's release folder, checked against the .sha256 beside it. It is kept as an initrd
#    (rootfs.cpio.gz: the same files with their owners, converted by macOS's tar); a new machine copies itself
#    from it onto its disk at its first start.
#  - myLinux's own kernel (Image, about 14 MB) from the latest image release on mylinux-releases, checked against
#    that release's SHA256SUMS: it has the virtio disk, network and 9p share built in, so it boots without modules,
#    firmware or a boot loader.
# Usage: tools/get-tiny.sh            the latest of both
#        tools/get-tiny.sh --remove   delete the download (machines keep their own disks and kernels)
#        tools/get-tiny.sh --check    the saved and the latest revision (tools/download-cache.sh)
set -eu
cd "$(dirname "$0")/.."
. tools/download-cache.sh
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64"
REPO=adminmylinux/mylinux-releases
FETCH="--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20"
OUT="${MYLINUX_OUT:-out}"
DEST="$OUT/tiny"
if [ "${1:-}" = --remove ]; then rm -rf "$DEST" "$DEST.prev"; echo "removed $DEST"; exit 0; fi
CHECK=0; [ "${1:-}" = --check ] && { CHECK=1; FETCH="--retry 1 --retry-delay 2 --connect-timeout 10"; }
CACHED=$(cache_rev tiny TINY-REVISION)
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the Tiny Alpine machine is for Apple-silicon Macs" >&2; exit 1; }
mkdir -p "$OUT"
STAGE="$OUT/.staging-tiny$([ "$CHECK" = 1 ] && echo -check || true)"
rm -rf "$STAGE"; mkdir -p "$STAGE/new"; trap 'rm -rf "$STAGE"' EXIT
complete() { [ -s "$1/Image" ] && [ -s "$1/rootfs.cpio.gz" ]; }
REVISION=""
if [ "${MYLINUX_FROM_CACHE:-0}" = 1 ] && [ -n "$CACHED" ]; then
  REVISION=$CACHED
else
  echo "looking up the latest Alpine and kernel ..."
  ROOTFS=""; TAG=""
  # shellcheck disable=SC2086
  if curl -fsSL $FETCH --max-time 60 -o "$STAGE/listing.html" "$BASE/"; then
    # alpine-minirootfs-3.24.2-aarch64.tar.gz: the highest release (release candidates, 3.25.0_rc1, are not taken)
    ROOTFS=$(grep -oE 'alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-aarch64\.tar\.gz' "$STAGE/listing.html" | sort -u \
      | sed -E 's/^alpine-minirootfs-([0-9]+)\.([0-9]+)\.([0-9]+)-aarch64\.tar\.gz$/\1 \2 \3 &/' \
      | sort -n -k1,1 -k2,2 -k3,3 | tail -1 | cut -d' ' -f4)
    [ -n "$ROOTFS" ] || { echo "no aarch64 mini root filesystem in $BASE/" >&2; exit 1; }
  fi
  # the redirect target of /releases/latest names the tag; no API token needed
  # shellcheck disable=SC2086
  TAG=$(curl -fsSIL $FETCH --max-time 60 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's#.*/tag/##') || TAG=""
  case "$TAG" in v[0-9]*) ;; *) TAG="" ;; esac
  # "3.24.2 v0.2.0": Alpine's release and the kernel's
  [ -z "$ROOTFS" ] || [ -z "$TAG" ] || REVISION="$(printf '%s' "$ROOTFS" | sed -E 's/^alpine-minirootfs-(.*)-aarch64\.tar\.gz$/\1/') $TAG"
  [ "$CHECK" = 1 ] && { check_report "$CACHED" "$REVISION"; exit 0; }
  if [ -z "$REVISION" ]; then
    [ -n "$CACHED" ] || { echo "the download servers are not answering right now (dl-cdn.alpinelinux.org, github.com); try again in a few minutes" >&2; exit 1; }
    echo "the download servers are not answering; installing the saved Tiny Alpine $CACHED"
    REVISION=$CACHED
  fi
fi
if [ "$(cat "$DEST/TINY-REVISION" 2>/dev/null)" = "$REVISION" ] && complete "$DEST"; then
  echo "ok: $DEST already is Tiny Alpine $REVISION"; exit 0
fi
if [ -n "$CACHED" ] && [ "$CACHED" = "$REVISION" ]; then
  echo "installing Tiny Alpine $REVISION from the saved download ..."
  rm -rf "$STAGE/new"; cache_clone "$CACHE/tiny" "$STAGE/new"
  complete "$STAGE/new" || { echo "the saved Tiny Alpine is incomplete: nothing installed (Settings › Storage can remove the saved downloads)" >&2; exit 1; }
  rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
  mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
  echo "ok: $DEST is Tiny Alpine $REVISION (Image, rootfs.cpio.gz). Start a machine with ./run-tiny.sh"
  exit 0
fi
echo "downloading Tiny Alpine $REVISION (about 18 MB) ..."
# shellcheck disable=SC2086
curl -fsSL $FETCH --max-time 60 -o "$STAGE/$ROOTFS.sha256" "$BASE/$ROOTFS.sha256"
# shellcheck disable=SC2086
curl -fL $FETCH --progress-bar -o "$STAGE/$ROOTFS" "$BASE/$ROOTFS"
WANT=$(cut -d' ' -f1 < "$STAGE/$ROOTFS.sha256" | tr -d '\n')
[ ${#WANT} = 64 ] || { echo "$ROOTFS.sha256 is not a SHA-256 checksum: nothing installed" >&2; exit 1; }
[ "$(shasum -a 256 "$STAGE/$ROOTFS" | cut -d' ' -f1)" = "$WANT" ] || { echo "the download does not match $ROOTFS.sha256: nothing installed" >&2; exit 1; }
KBASE="https://github.com/$REPO/releases/download/$TAG"
# shellcheck disable=SC2086
curl -fsSL $FETCH --max-time 60 -o "$STAGE/SHA256SUMS" "$KBASE/SHA256SUMS"
# shellcheck disable=SC2086
curl -fL $FETCH --progress-bar -o "$STAGE/new/Image" "$KBASE/Image"
WANT=$(awk '$2 == "Image" { print $1 }' "$STAGE/SHA256SUMS")
[ ${#WANT} = 64 ] && [ "$(shasum -a 256 "$STAGE/new/Image" | cut -d' ' -f1)" = "$WANT" ] || { echo "the kernel does not match $TAG's SHA256SUMS: nothing installed" >&2; exit 1; }
echo "converting ..."
# nothing in the archive may point outside it; then macOS's tar rewrites it as an initrd, owners and modes as they are
if /usr/bin/tar -tzf "$STAGE/$ROOTFS" | grep -q -E '(^/|(^|/)\.\.(/|$))'; then echo "unexpected paths in $ROOTFS: nothing installed" >&2; exit 1; fi
/usr/bin/tar --format newc -cf - "@$STAGE/$ROOTFS" | gzip -9 > "$STAGE/new/rootfs.cpio.gz" || { echo "could not convert $ROOTFS: nothing installed" >&2; exit 1; }
gzip -dc "$STAGE/new/rootfs.cpio.gz" | /usr/bin/tar -tf - | grep -q '^\(\./\)\{0,1\}bin/busybox$' || { echo "$ROOTFS has no BusyBox: nothing installed" >&2; exit 1; }
printf '%s\n' "$REVISION" > "$STAGE/new/TINY-REVISION"
rm -rf "$DEST.prev"; [ -d "$DEST" ] && mv "$DEST" "$DEST.prev"
mv "$STAGE/new" "$DEST"; rm -rf "$DEST.prev"
cache_store tiny "$DEST"
echo "ok: $DEST is Tiny Alpine $REVISION (Image, rootfs.cpio.gz). Start a machine with ./run-tiny.sh"
