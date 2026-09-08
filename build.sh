#!/bin/sh
# Run from macOS: build the image inside the OrbStack Debian machine and copy the results to out/.
# Usage: ./build.sh            (full/incremental build)
#        ./build.sh myapp-rebuild all   (any make targets)
set -e
cd "$(dirname "$0")"
HERE="$PWD"
# Buildroot re-syncs local-source packages (myapp, myshell) only on <pkg>-rebuild, so force it.
orb run -m debian sh -c "cd ~/br/output && make -j\$(nproc) ${*:-myapp-rebuild myshell-rebuild all} 2>&1 | tee -a build.log | grep --line-buffered -E '^>>> |Error|error:|warning: .*(failed|missing)' ; test \${PIPESTATUS:-0} -eq 0"
orb run -m debian sh -c "cp ~/br/output/images/Image ~/br/output/images/rootfs.cpio.gz '$HERE/out/'"
ls -la out/
