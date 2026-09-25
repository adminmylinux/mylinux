#!/bin/sh
# Create out/myLinux.app (or $MYLINUX_OUT/myLinux.app): a thin macOS bundle around Homebrew's QEMU so the Mac shows "myLinux"
# as the app name, Dock icon and window title. run.sh calls this.
# With APP_ID (a machine's id, from the launcher) the machine also gets a bundle of its own,
# $OUT/machines/<APP_ID>/<APP_NAME>.app, with APP_NAME as its name and APP_ICON (an .icns) as its icon, so each
# machine is its own app in the Dock and ⌘Tab; QEMU in it is an APFS clone of the shared one (no extra disk space).
# The last line of output is "<bundle> ready": run.sh starts QEMU from that bundle.
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
[ -n "${APP_ID:-}" ] || { echo "$APP ready"; exit 0; }

# ---- the machine's own bundle ---------------------------------------------------------------------------------------
case "$APP_ID" in *[!0-9A-Fa-f-]*|"") echo "APP_ID must be a machine id" >&2; exit 1 ;; esac
ID=$(printf '%s' "$APP_ID" | tr 'A-F' 'a-f')
NAME=$(printf '%s' "${APP_NAME:-myLinux}" | tr '/:' '--' | sed 's/^\.*//'); [ -n "$NAME" ] || NAME=myLinux
DIR="$OUT/machines/$ID"; MAPP="$DIR/$NAME.app"
mkdir -p "$DIR"
# a renamed machine: the bundle under its old name goes
for old in "$DIR"/*.app; do [ -e "$old" ] && [ "$old" != "$MAPP" ] && rm -rf "$old"; done
mkdir -p "$MAPP/Contents/MacOS" "$MAPP/Contents/Resources"
MBIN="$MAPP/Contents/MacOS/qemu-myLinux"
if [ ! -f "$MBIN" ] || ! cmp -s "$BIN" "$MBIN"; then
  rm -f "$MBIN.new"; cp -c "$BIN" "$MBIN.new" 2>/dev/null || cp "$BIN" "$MBIN.new"
  mv -f "$MBIN.new" "$MBIN"
fi
# the Dock and Finder entry point: this machine, started (or brought forward) by the launcher
cat > "$MAPP/Contents/MacOS/myLinux.new" <<SH
#!/bin/sh
case "\${1:-}" in ''|-psn_*) exec /usr/bin/open "mylinux-launcher://start/$ID" ;; esac
exec "\$(dirname "\$0")/qemu-myLinux" "\$@"
SH
chmod +x "$MAPP/Contents/MacOS/myLinux.new" && mv -f "$MAPP/Contents/MacOS/myLinux.new" "$MAPP/Contents/MacOS/myLinux"
rm -f "$MAPP/Contents/share" "$MAPP/Contents/lib"
[ -e "$APP/Contents/lib" ] && ln -sfn "$(readlink "$APP/Contents/lib")" "$MAPP/Contents/lib"
[ -e "$APP/Contents/share" ] && ln -sfn "$(readlink "$APP/Contents/share")" "$MAPP/Contents/share"
XNAME=$(printf '%s' "$NAME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
cat > "$MAPP/Contents/Info.plist.new" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$XNAME</string>
  <key>CFBundleDisplayName</key><string>$XNAME</string>
  <key>CFBundleExecutable</key><string>myLinux</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.$ID</string>
  <key>CFBundleIconFile</key><string>machine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>NSHighResolutionCapable</key><$HIDPI/>
</dict></plist>
PLIST
if cmp -s "$MAPP/Contents/Info.plist.new" "$MAPP/Contents/Info.plist"; then rm -f "$MAPP/Contents/Info.plist.new"
else mv -f "$MAPP/Contents/Info.plist.new" "$MAPP/Contents/Info.plist"; touch "$MAPP"; fi
MICNS="$MAPP/Contents/Resources/machine.icns"
SRC="${APP_ICON:-$ICNS}"
if [ -f "$SRC" ] && ! cmp -s "$SRC" "$MICNS"; then cp -f "$SRC" "$MICNS" && touch "$MAPP"; fi
echo "$MAPP ready"
