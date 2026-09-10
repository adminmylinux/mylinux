#!/bin/sh
# Create out/myLinux.app: a thin macOS bundle around Homebrew's QEMU so the Mac shows "myLinux"
# as the app name, Dock icon and window title. run.sh calls this.
set -eu
cd "$(dirname "$0")/.."
APP=out/myLinux.app
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
# icon: rounded gradient square with a window glyph, rendered by tools/gen-icon.py, converted with sips
[ -f "$APP/Contents/Resources/myLinux.icns" ] || {
  python3 tools/gen-icon.py "$APP/Contents/Resources/myLinux.png"
  sips -s format icns "$APP/Contents/Resources/myLinux.png" --out "$APP/Contents/Resources/myLinux.icns" >/dev/null
}
echo "$APP ready"
