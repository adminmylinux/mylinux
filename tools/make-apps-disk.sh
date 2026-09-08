#!/bin/sh
# Build out/apps.img: a sparse ext4 disk holding a Debian arm64 chroot ("apps disk") with apt and
# Chromium. Runs inside the OrbStack Debian machine (needs sudo for loop mounts). ~10 min, ~2.5 GB.
# Usage: tools/make-apps-disk.sh [size]   (default 8G, sparse)   Re-run to rebuild from scratch.
set -e
SIZE="${1:-8G}"
cd "$(dirname "$0")/.."
HERE="$PWD"; BR="/home/$(id -un)/br"; ME="$(id -un)"
orb run -m debian sudo sh -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  (command -v debootstrap >/dev/null && command -v mkfs.ext4 >/dev/null) || (apt-get update -q && apt-get install -y -q debootstrap e2fsprogs)
  IMG=$BR/apps.img; MNT=/mnt/apps-build
  rm -f \$IMG; truncate -s $SIZE \$IMG; mkfs.ext4 -q -L apps \$IMG
  mkdir -p \$MNT; mount -o loop \$IMG \$MNT
  debootstrap --arch=arm64 --variant=minbase --include=ca-certificates,fonts-dejavu-core,libgl1,libegl1,libgles2,mesa-libgallium,dbus,xdg-utils,wl-clipboard,curl trixie \$MNT http://deb.debian.org/debian
  mount --bind /dev \$MNT/dev; mount -t proc proc \$MNT/proc; mount -t sysfs sys \$MNT/sys
  chroot \$MNT sh -c 'apt-get update -q && apt-get install -y -q --no-install-recommends chromium chromium-sandbox fonts-liberation && apt-get clean'
  umount \$MNT/sys \$MNT/proc \$MNT/dev
  du -sh \$MNT; umount \$MNT
  cp --sparse=always \$IMG '$HERE/out/apps.img' && chown $ME '$HERE/out/apps.img'
"
ls -la out/apps.img; du -h out/apps.img
