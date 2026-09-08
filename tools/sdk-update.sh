#!/bin/sh
# Re-export the Buildroot SDK after the image config changes (new Qt modules, Mesa, ...) so
# tools/app-build.sh links against the same libraries the image ships. Runs inside Debian.
set -e
orb run -m debian sh -c '
  set -e
  cd ~/br/output && make sdk 2>&1 | grep -E "^>>> .*(sdk|SDK)" || true
  rm -rf ~/br/sdk && mkdir -p ~/br/sdk
  tar -xzf images/aarch64-buildroot-linux-gnu_sdk-buildroot.tar.gz -C ~/br/sdk --strip-components=1
  cd ~/br/sdk && ./relocate-sdk.sh | tail -1
  rm -rf ~/br/app-build
  du -sh ~/br/sdk
'
