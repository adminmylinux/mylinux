#!/bin/sh
# Create out/myLinux.app (or $MYLINUX_OUT/myLinux.app): a thin macOS bundle around Homebrew's QEMU so the Mac shows "myLinux"
# as the app name, Dock icon and window title. run.sh calls this.
# Contents/MacOS/qemu-myLinux is QEMU (run.sh starts it with the machine's arguments); Contents/MacOS/myLinux, the
# bundle's main executable, is a small script for launches from the Dock or Finder: with no arguments there is no
# machine to run, so it asks myLinux Launcher to start the last-used machine (or bring a running one forward).
set -eu
cd "$(dirname "$0")/.."
# python3 is optional: without Xcode's command line tools the stub fails and asks to install them
have_python() {
  [ -x /opt/homebrew/bin/python3 ] || [ -x /usr/local/bin/python3 ] && return 0
  dev=$(xcode-select -p 2>/dev/null) || return 1
  # with Xcode, /usr/bin/python3 goes through xcrun, which refuses to run anything until the Xcode licence is accepted
  case "$dev" in */CommandLineTools) [ -x "$dev/usr/bin/python3" ] ;; *) xcodebuild -license check >/dev/null 2>&1 ;; esac
}
OUT="${MYLINUX_OUT:-out}"
# Two bundles from the same recipe. myLinux.app is 1x on purpose (see NSHighResolutionCapable below). run-omarchy.sh
# asks for the other one (MYLINUX_BUNDLE=omarchy): the runtime's Cocoa display tells that guest the window's size in
# backing pixels and scales the picture by the backing factor, which only adds up in a Retina-capable app.
case "${MYLINUX_BUNDLE:-mylinux}" in
  mylinux) APP="$OUT/myLinux.app"; HIDPI=false; BUNDLE_ID=dev.mylinux.vm ;;
  omarchy) APP="$OUT/myLinux-omarchy.app"; HIDPI=true; BUNDLE_ID=dev.mylinux.vm.omarchy ;;
  *) echo "MYLINUX_BUNDLE must be mylinux or omarchy" >&2; exit 1 ;;
esac
# Which QEMU: the accelerated runtime in $OUT/qemu-runtime (tools/get-qemu-runtime.sh: VirGL, self-contained, no
# Homebrew needed) when it is there, else Homebrew's. MYLINUX_QEMU=brew insists on Homebrew's. run.sh asks the same
# question (tools/qemu-flavour.sh) because the two take different machine arguments.
FLAVOUR=$(sh tools/qemu-flavour.sh "$OUT")
if [ "$FLAVOUR" = runtime ]; then
  QEMU="$OUT/qemu-runtime/bin/qemu-system-aarch64"
else
  QEMU=$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v qemu-system-aarch64) || { echo "qemu-system-aarch64 not found (brew install qemu, or tools/get-qemu-runtime.sh)" >&2; exit 1; }
  QEMU=$(readlink -f "$QEMU" 2>/dev/null || echo "$QEMU")
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/qemu-myLinux"
# A patched copy of QEMU (window title and app-menu items say myLinux, see tools/brand-qemu.py),
# refreshed whenever Homebrew's binary changes. Patched into a temporary file and moved into place,
# so a failed patch leaves the previous binary; if the patcher cannot handle this QEMU (new Mach-O
# layout), an unbranded copy is used with a warning instead of no app at all.
# ($BIN.source names the binary the copy was made from, so switching between the runtime and Homebrew refreshes it.)
if [ -L "$BIN" ] || [ ! -f "$BIN" ] || [ "$QEMU" -nt "$BIN" ] || [ "$(cat "$BIN.source" 2>/dev/null)" != "$QEMU" ]; then
  if have_python && python3 tools/brand-qemu.py "$QEMU" "$BIN.new"; then
    mv -f "$BIN.new" "$BIN"
  else
    have_python && echo "warning: could not brand QEMU (tools/brand-qemu.py failed); using an unbranded copy" >&2
    rm -f "$BIN.new"
    cp -f "$QEMU" "$BIN.new" && codesign --force --sign - --entitlements /dev/stdin "$BIN.new" <<'ENT' && mv -f "$BIN.new" "$BIN"
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
ENT
  fi
fi
printf '%s\n' "$QEMU" > "$BIN.source"
# the Dock/Finder entry point (replaces the QEMU binary that bundles before 2026-09-14 had under this name)
cat > "$APP/Contents/MacOS/myLinux.new" <<'SH'
#!/bin/sh
# myLinux opened from the Dock or Finder: no machine arguments, so hand over to myLinux Launcher.
# Anything with arguments is QEMU's business (an older run.sh calling the previous binary name).
case "${1:-}" in ''|-psn_*) exec /usr/bin/open "mylinux-launcher://start" ;; esac
exec "$(dirname "$0")/qemu-myLinux" "$@"
SH
chmod +x "$APP/Contents/MacOS/myLinux.new" && mv -f "$APP/Contents/MacOS/myLinux.new" "$APP/Contents/MacOS/myLinux"
# QEMU finds its data (BIOS/ROM files, keymaps) at <bindir>/../share/qemu; point it at Homebrew's. The runtime has
# no data files (run.sh passes romfile= for it) but loads its libraries from <bindir>/../lib.
rm -f "$APP/Contents/share" "$APP/Contents/lib"
if [ "$FLAVOUR" = runtime ]; then
  ln -sfn "$(cd "$OUT/qemu-runtime/lib" && pwd)" "$APP/Contents/lib"
else
  ln -sfn "$(dirname "$(dirname "$QEMU")")/share" "$APP/Contents/share"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>myLinux</string>
  <key>CFBundleDisplayName</key><string>myLinux</string>
  <key>CFBundleExecutable</key><string>myLinux</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>myLinux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <!-- 1x backing store on purpose: QEMU sizes a non-resizable window in device pixels, so with a 1x
       window one guest pixel is one point and the desktop appears at the size run.sh asked for. -->
  <key>NSHighResolutionCapable</key><$HIDPI/>
</dict></plist>
PLIST
# icon: tools/icons/myLinux.icns (drawn by tools/icons/make-icons.sh, committed), refreshed whenever it changes so an
# existing bundle picks up a new icon; the Finder and Dock cache icons, so the bundle is touched after a change.
# Without that file (an old checkout), tools/gen-icon.py renders the original one. No icon is not an error.
ICNS="$APP/Contents/Resources/myLinux.icns"
if [ -f tools/icons/myLinux.icns ]; then
  if ! cmp -s tools/icons/myLinux.icns "$ICNS"; then cp -f tools/icons/myLinux.icns "$ICNS" && touch "$APP"; fi
elif [ ! -f "$ICNS" ]; then
  if have_python && python3 tools/gen-icon.py "$APP/Contents/Resources/myLinux.png" 2>/dev/null; then
    sips -s format icns "$APP/Contents/Resources/myLinux.png" --out "$ICNS" >/dev/null || true
  else echo "warning: no icon (python3 unavailable)" >&2; fi
fi
echo "$APP ready"
