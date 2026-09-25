#!/bin/sh
# Render the app icons (tools/icons/icons.swift) and pack them as .icns next to this script:
#   tools/icons/myLinux.icns            the desktop (QEMU wrapper, tools/make-app-bundle.sh)
#   tools/icons/myLinux Launcher.icns   the Mac launcher app (mac/build-app.sh)
#   tools/icons/machine-*.icns   the machines' own apps (one per machine, MachineApp.swift)
# The results are committed, so building the apps never needs this; rerun it after changing the drawing.
set -eu
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift icons.swift "$TMP" >/dev/null
for name in "myLinux" "myLinux Launcher" machine-omarchy machine-debian machine-alpine; do
  set_dir="$TMP/$name.iconset"
  mkdir -p "$set_dir"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/$name.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$TMP/$name.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$set_dir" -o "$name.icns"
  cp "$TMP/$name.png" "$name.png"
  echo "tools/icons/$name.icns"
done
