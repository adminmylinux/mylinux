#!/bin/sh
# Build the myLinux Mac app: a launcher around run.sh with saved machine profiles.
# Usage: mac/build-app.sh              -> "out/mac/myLinux Launcher.app"
#        mac/build-app.sh --install    -> also copies it to /Applications
# The app carries its own copy of run.sh and the helper scripts, so it works on a Mac without this checkout
# (images are then downloaded into ~/Library/Application Support/myLinux). Needs Xcode's Swift and Homebrew QEMU
# at run time. The bundle is signed ad hoc: on another Mac, Gatekeeper needs the usual right-click > Open.
set -eu
cd "$(dirname "$0")/.."
REPO=$PWD
# The QEMU wrapper run.sh starts is also called "myLinux" (its window and menu bar are the desktop itself), so
# the launcher carries the longer name: two apps with one name collide in the Dock, in ⌘Tab and in scripting.
APP="out/mac/myLinux Launcher.app"
NEW="out/mac/.myLinux Launcher.app.new"

command -v swift >/dev/null || { echo "swift not found (install Xcode or the Command Line Tools)" >&2; exit 1; }
(cd mac && swift build -c release --product myLinux)
BIN="$(cd mac && swift build -c release --show-bin-path)/myLinux"
[ -x "$BIN" ] || { echo "the launcher binary was not built" >&2; exit 1; }

rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources/runtime/tools"
cp "$BIN" "$NEW/Contents/MacOS/myLinux Launcher"
# the scripts the app runs: run.sh and everything it calls
cp run.sh "$NEW/Contents/Resources/runtime/"
for f in make-app-bundle.sh brand-qemu.py gen-icon.py clipboard-host.sh host-window.sh get-image.sh; do
  cp "tools/$f" "$NEW/Contents/Resources/runtime/tools/"
done
# icons (tools/icons/make-icons.sh): the launcher's own, and the desktop's for the QEMU wrapper make-app-bundle.sh builds
mkdir -p "$NEW/Contents/Resources/runtime/tools/icons"
cp "tools/icons/myLinux Launcher.icns" "$NEW/Contents/Resources/myLinux Launcher.icns"
cp tools/icons/myLinux.icns "$NEW/Contents/Resources/runtime/tools/icons/myLinux.icns"

VERSION=$(git -C "$REPO" describe --tags --always 2>/dev/null || echo 0.1)
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>myLinux Launcher</string>
  <key>CFBundleDisplayName</key><string>myLinux Launcher</string>
  <key>CFBundleExecutable</key><string>myLinux Launcher</string>
  <key>CFBundleIdentifier</key><string>dev.mylinux.launcher</string>
  <key>CFBundleIconFile</key><string>myLinux Launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- the checkout this was built from; offered as the developer checkout when it is still there -->
  <key>MyLinuxRepo</key><string>$REPO</string>
</dict></plist>
PLIST

codesign --force --sign - "$NEW" >/dev/null 2>&1 || echo "warning: could not sign the app" >&2
rm -rf "$APP"
mv "$NEW" "$APP"
echo "$APP ready"

if [ "${1:-}" = --install ]; then
  rm -rf "/Applications/myLinux Launcher.app"
  cp -R "$APP" /Applications/
  echo "installed /Applications/myLinux Launcher.app"
fi
