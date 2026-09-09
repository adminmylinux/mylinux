#!/bin/sh
# Cross-build a Qt project of this repo with the Buildroot SDK (inside the OrbStack Debian machine)
# and drop the binary into share/, which run.sh exposes to the VM as 9p tag "share".
# S99shell prefers /mnt/share/myshell and /mnt/share/myapp over the image's copies.
# Usage: tools/app-build.sh            build app/   (myapp)
#        tools/app-build.sh shell      build shell/ (myshell)
#        tools/app-build.sh clean      wipe the build dirs
set -e
cd "$(dirname "$0")/.."
HERE="$PWD"
BR="/home/$(id -un)/br"   # Buildroot tree inside the Debian machine
SDK=$BR/sdk
case "${1:-app}" in
  app)   DIR=app;   BIN=myapp ;;
  shell) DIR=shell; BIN=myshell ;;
  clean) orb run -m debian rm -rf $BR/app-build $BR/shell-build; exit 0 ;;
  *) echo "usage: $0 [app|shell|clean]"; exit 2 ;;
esac
BUILD=$BR/$DIR-build
orb run -m debian sh -c "
  set -e
  mkdir -p '$BUILD' && cd '$BUILD'
  sleep 2   # OrbStack's shared-FS attribute cache: give fresh mtimes from the Mac time to land
  [ -f CMakeCache.txt ] || cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE='$SDK/share/buildroot/toolchainfile.cmake' -DCMAKE_BUILD_TYPE=Release '$HERE/$DIR' > cmake.log
  if ! ninja > ninja.log 2>&1; then grep -v '^\[' ninja.log | tail -25; echo 'BUILD FAILED'; exit 1; fi
  tail -2 ninja.log
  cp -f $BIN '$HERE/share/$BIN'
"
ls -la share/$BIN
echo "In the VM: /etc/init.d/S99shell restart   (or reboot)"
