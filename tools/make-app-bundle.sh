#!/bin/sh
# Create out/myLinux.app (or $MYLINUX_OUT/myLinux.app): a thin macOS bundle around Homebrew's QEMU so the Mac shows "myLinux"
# as the app name, Dock icon and window title. run.sh calls this.
set -eu
cd "$(dirname "$0")/.."
APP="${MYLINUX_OUT:-out}/myLinux.app"
QEMU=$(command -v qemu-system-aarch64) || { echo "qemu-system-aarch64 not found (brew install qemu)" >&2; exit 1; }
QEMU=$(readlink -f "$QEMU" 2>/dev/null || echo "$QEMU")
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/myLinux"
# A patched copy of QEMU (window title and app-menu items say myLinux, see tools/brand-qemu.py),
# refreshed whenever Homebrew's binary changes. Patched into a temporary file and moved into place,
# so a failed patch leaves the previous binary; if the patcher cannot handle this QEMU (new Mach-O
# layout), an unbranded copy is used with a warning instead of no app at all.
if [ -L "$BIN" ] || [ ! -f "$BIN" ] || [ "$QEMU" -nt "$BIN" ]; then
  if python3 tools/brand-qemu.py "$QEMU" "$BIN.new"; then
    mv -f "$BIN.new" "$BIN"
  else
    echo "warning: could not brand QEMU (tools/brand-qemu.py failed); using an unbranded copy" >&2
    rm -f "$BIN.new"
    cp -f "$QEMU" "$BIN.new" && codesign --force --sign - --entitlements /dev/stdin "$BIN.new" <<'ENT' && mv -f "$BIN.new" "$BIN"
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
ENT
  fi
fi
# QEMU finds its data (BIOS/ROM files, keymaps) at <bindir>/../share/qemu; point it at Homebrew's.
ln -sfn "$(dirname "$(dirname "$QEMU")")/share" "$APP/Contents/share"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>myLinux</string>
  <key>CFBundleDisplayName</key><string>myLinux</string>
  <key>CFBundleExecutable</key><string>myLinux</string>
  <key>CFBundleIdentifier</key><string>dev.mylinux.vm</string>
  <key>CFBundleIconFile</key><string>myLinux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <!-- 1x backing store on purpose: QEMU sizes a non-resizable window in device pixels, so with a 1x
       window one guest pixel is one point and the desktop appears at the size run.sh asked for. -->
  <key>NSHighResolutionCapable</key><false/>
</dict></plist>
PLIST
# icon: tools/icons/myLinux.icns (drawn by tools/icons/make-icons.sh, committed), refreshed whenever it changes so an
# existing bundle picks up a new icon; the Finder and Dock cache icons, so the bundle is touched after a change.
# Without that file (an old checkout), tools/gen-icon.py renders the original one. No icon is not an error.
ICNS="$APP/Contents/Resources/myLinux.icns"
if [ -f tools/icons/myLinux.icns ]; then
  if ! cmp -s tools/icons/myLinux.icns "$ICNS"; then cp -f tools/icons/myLinux.icns "$ICNS" && touch "$APP"; fi
elif [ ! -f "$ICNS" ]; then
  if python3 tools/gen-icon.py "$APP/Contents/Resources/myLinux.png" 2>/dev/null; then
    sips -s format icns "$APP/Contents/Resources/myLinux.png" --out "$ICNS" >/dev/null || true
  else echo "warning: no icon (python3 unavailable)" >&2; fi
fi
echo "$APP ready"
