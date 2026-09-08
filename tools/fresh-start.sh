#!/bin/sh
# Boot mylinux exactly as a brand-new user would: a blank apps disk and empty settings, without
# touching your real out/apps.img or share/. Re-running resets the fresh environment.
# Usage: tools/fresh-start.sh            fresh boot (wipes the previous fresh disk + settings)
#        tools/fresh-start.sh keep       boot the fresh environment again, keeping its disk
cd "$(dirname "$0")/.."
FRESH_IMG=out/apps-fresh.img
FRESH_SHARE=out/fresh-share
if [ "$1" != keep ]; then
  rm -rf "$FRESH_IMG" "$FRESH_SHARE"
  echo "fresh start: blank apps disk + default settings (your out/apps.img and share/ are untouched)"
else
  echo "fresh environment: keeping $FRESH_IMG and $FRESH_SHARE"; shift
fi
mkdir -p "$FRESH_SHARE"
APPS_IMG="$FRESH_IMG" SHARE_DIR="$FRESH_SHARE" exec ./run.sh "$@"
