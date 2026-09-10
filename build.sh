#!/bin/sh
# Run from macOS: build the image inside the OrbStack Debian machine and copy the results to out/.
# Usage: ./build.sh            (full/incremental build)
#        ./build.sh myapp-rebuild all   (any make targets)
# The build's exit status is the real one (bash pipefail inside Debian, no grep in the status path);
# artifacts are staged and promoted as a kernel + rootfs pair only after a successful build, so a
# failed build never replaces a working image. The image records the git revision it was built from.
set -eu
cd "$(dirname "$0")"
HERE="$PWD"
REV=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain 2>/dev/null)" ] || REV="$REV-dirty"
# Buildroot re-syncs local-source packages (myapp, myshell) only on <pkg>-rebuild, so force it.
TARGETS="${*:-myapp-rebuild myshell-rebuild all}"
mkdir -p out/.staging board/overlay/etc
printf 'myLinux %s built %s\n' "$REV" "$(date -u +%Y-%m-%dT%H:%MZ)" > board/overlay/etc/mylinux-release
echo ">>> build $REV: make $TARGETS"
# bash is available in the Debian machine; `set -o pipefail` keeps make's status through tee/grep
if ! orb run -m debian bash -c "cd ~/br/output && set -o pipefail && make -j\$(nproc) $TARGETS 2>&1 | tee -a build.log | { grep --line-buffered -E '^>>> |Error|error:|warning: .*(failed|missing)' || true; }"; then
  echo "BUILD FAILED (see ~/br/output/build.log in the Debian machine); out/ left untouched" >&2
  exit 1
fi
orb run -m debian sh -c "cp ~/br/output/images/Image ~/br/output/images/rootfs.cpio.gz '$HERE/out/.staging/'"
for f in Image rootfs.cpio.gz; do [ -s "out/.staging/$f" ] || { echo "BUILD FAILED: missing $f" >&2; exit 1; }; done
# keep the previous pair, then promote the new pair (two renames; the pair is consistent once both are done)
for f in Image rootfs.cpio.gz; do [ -f "out/$f" ] && mv -f "out/$f" "out/$f.prev"; done
for f in Image rootfs.cpio.gz; do mv -f "out/.staging/$f" "out/$f"; done
echo "$REV" > out/IMAGE-REVISION
ls -la out/Image out/rootfs.cpio.gz
echo "image revision: $REV (previous pair kept as out/*.prev)"
