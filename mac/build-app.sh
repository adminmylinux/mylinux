#!/bin/sh
# Build the myLinux Mac app: a launcher around run.sh with saved machine profiles.
# Usage: mac/build-app.sh              -> "out/mac/myLinux Launcher.app"
#        mac/build-app.sh --install    -> also copies it to /Applications
# The app carries its own copy of run.sh and the helper scripts, and libvncclient with its libraries in
# Contents/Frameworks, so it works on a Mac without this checkout or Homebrew (images are then downloaded into
# ~/Library/Application Support/myLinux). Needs Xcode's Swift and Homebrew's libvncserver to build. At run time QEMU is
# the accelerated runtime (Settings > QEMU downloads it, or a release build carries it) or Homebrew's.
# Environment: MYLINUX_RELEASE=1      a build for other Macs: the QEMU runtime tarball (out/qemu-runtime-macos-arm64.tar.gz,
#                                     it must be the version in tools/qemu-runtime.version) rides inside and is installed on
#                                     first start; no developer checkout path in Info.plist
#              MYLINUX_SIGN_IDENTITY  a codesigning identity ("Developer ID Application: ..." for a notarised release);
#                                     default: the local "myLinux Launcher (local signing)" certificate when there is one
#                                     (a stable signature keeps the Accessibility permission across rebuilds), else ad hoc.
#                                     mac/release.sh does the release build, DMG and notarisation.
set -eu
cd "$(dirname "$0")/.."
REPO=$PWD
# The QEMU wrapper run.sh starts is also called "myLinux" (its window and menu bar are the desktop itself), so
# the launcher carries the longer name: two apps with one name collide in the Dock, in ⌘Tab and in scripting.
APP="out/mac/myLinux Launcher.app"
NEW="out/mac/.myLinux Launcher.app.new"

command -v swift >/dev/null || { echo "swift not found (install Xcode or the Command Line Tools)" >&2; exit 1; }
# libvncclient: the copy tools/build-libvncclient.sh made for macOS 15 (out/libvnc) when it is there, else Homebrew's
if [ -f out/libvnc/lib/pkgconfig/libvncclient.pc ]; then
  export PKG_CONFIG_PATH="$REPO/out/libvnc/lib/pkgconfig:${PKG_CONFIG_PATH:-}"; echo "libvncclient: out/libvnc (built for macOS 15)"
else
  export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}:/opt/homebrew/lib/pkgconfig"; echo "libvncclient: Homebrew's"
  [ "${MYLINUX_RELEASE:-0}" = 1 ] && { echo "a release needs the libraries from tools/build-libvncclient.sh: Homebrew's are built for this Mac's macOS only" >&2; exit 1; }
fi
(cd mac && swift build -c release --product myLinux)
BIN="$(cd mac && swift build -c release --show-bin-path)/myLinux"
[ -x "$BIN" ] || { echo "the launcher binary was not built" >&2; exit 1; }

rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources/runtime/tools"
cp "$BIN" "$NEW/Contents/MacOS/myLinux Launcher"
# libvncclient and what it needs (jpeg, OpenSSL) come along in Contents/Frameworks: the binary and the libraries are
# rewritten to find them by @rpath, so the app runs on a Mac without Homebrew or this checkout. Anything linked by
# an absolute path outside the system (out/libvnc, /opt/homebrew) is bundled, with what it links in turn.
EXE="$NEW/Contents/MacOS/myLinux Launcher"
mkdir -p "$NEW/Contents/Frameworks"
brew_deps() { otool -L "$1" | awk 'NR > 1 && $1 ~ /^\// && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\// { print $1 }'; }
queue=$(brew_deps "$EXE"); bundled=""
while [ -n "$queue" ]; do
  next=""
  for lib in $queue; do
    name=$(basename "$lib")
    case " $bundled " in *" $name "*) continue ;; esac
    real=$(readlink -f "$lib" 2>/dev/null || echo "$lib")
    [ -f "$real" ] || { echo "library $lib is missing (brew install libvncserver)" >&2; exit 1; }
    cp "$real" "$NEW/Contents/Frameworks/$name"; chmod u+w "$NEW/Contents/Frameworks/$name"
    bundled="$bundled $name"
    for dep in $(brew_deps "$real"); do
      [ "$(basename "$dep")" = "$name" ] || next="$next $dep"
    done
  done
  queue=$next
done
for name in $bundled; do
  lib="$NEW/Contents/Frameworks/$name"
  install_name_tool -id "@rpath/$name" "$lib" 2>/dev/null
  for dep in $(brew_deps "$lib"); do install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib" 2>/dev/null; done
done
for dep in $(brew_deps "$EXE"); do install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$EXE" 2>/dev/null; done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
left=$(otool -L "$EXE" "$NEW"/Contents/Frameworks/*.dylib | awk '$1 ~ /^\// && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\// && $1 !~ /:$/' | wc -l | tr -d ' ')
[ "$left" = 0 ] || { echo "libraries outside the app are still referenced after bundling:" >&2; otool -L "$EXE" "$NEW"/Contents/Frameworks/*.dylib | awk '$1 ~ /^\// && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\//' >&2; exit 1; }
echo "bundled:$bundled"
# every bundled library must run on the oldest macOS the app declares (LSMinimumSystemVersion below); Homebrew's are
# built for the macOS they were installed on, which is what tools/build-libvncclient.sh is for
MINOS=15.0
for lib in "$NEW"/Contents/Frameworks/*.dylib; do
  m=$(otool -l "$lib" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  if [ "$(printf '%s\n%s\n' "$MINOS" "$m" | sort -V | head -1)" != "$MINOS" ] || [ "$m" = "" ]; then
    if [ "${MYLINUX_RELEASE:-0}" = 1 ]; then echo "$(basename "$lib") is built for macOS ${m:-?}, the app declares $MINOS: use tools/build-libvncclient.sh" >&2; exit 1
    else echo "note: $(basename "$lib") is built for macOS ${m:-?}; this build runs on this Mac but not on macOS $MINOS" >&2; fi
  fi
done
# the scripts the app runs: run.sh and everything it calls
cp run.sh run-omarchy.sh run-debian.sh "$NEW/Contents/Resources/runtime/"
mkdir -p "$NEW/Contents/Resources/runtime/omarchy" && cp -R omarchy/session "$NEW/Contents/Resources/runtime/omarchy/"
for f in make-app-bundle.sh brand-qemu.py gen-icon.py clipboard-host.sh host-window.sh get-image.sh get-qemu-runtime.sh get-omarchy.sh get-debian.sh omarchy-clipboard.py omarchy-session-mac.sh omarchy-bake-session.sh qemu-flavour.sh qemu-runtime.version; do
  cp "tools/$f" "$NEW/Contents/Resources/runtime/tools/"
done
# icons (tools/icons/make-icons.sh): the launcher's own, and the desktop's for the QEMU wrapper make-app-bundle.sh builds
mkdir -p "$NEW/Contents/Resources/runtime/tools/icons"
cp "tools/icons/myLinux Launcher.icns" "$NEW/Contents/Resources/myLinux Launcher.icns"
# the marks the welcome sheet shows: the launcher's and myLinux's own, Omarchy's (from its brand kit, via Try
# Omarchy) and Debian's Open Use Logo (Software in the Public Interest, LGPL-3 or CC-BY-SA 3.0)
mkdir -p "$NEW/Contents/Resources/icons"
cp "tools/icons/myLinux Launcher.png" tools/icons/myLinux.png tools/icons/omarchy.png tools/icons/debian.png "$NEW/Contents/Resources/icons/"
cp tools/icons/myLinux.icns "$NEW/Contents/Resources/runtime/tools/icons/myLinux.icns"

# Signed inside out: the libraries, then the app with its entitlements. MYLINUX_SIGN_IDENTITY, else the local
# "myLinux Launcher (local signing)" certificate when the login keychain has one (a stable signature keeps the
# Accessibility permission the full keyboard grab needs across rebuilds), else ad hoc. A Developer ID gets the
# hardened runtime and a timestamp, which notarisation requires; the hardened runtime's library validation only
# accepts libraries signed by the same team, so it is not used with a self-signed or ad hoc identity (no team).
IDENTITY=${MYLINUX_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(myLinux Launcher (local signing)\)".*/\1/p' | head -1)}
[ -n "$IDENTITY" ] || IDENTITY=-
case "$IDENTITY" in "Developer ID Application:"*) HARDENED=1 ;; *) HARDENED=0 ;; esac
sign() {
  if [ "$HARDENED" = 1 ]; then codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
  else codesign --force --sign "$IDENTITY" "$@"; fi; }

# a release build carries the QEMU runtime, installed into Application Support on the app's first start. Apple's
# notary service looks inside the tarball, so with a Developer ID every Mach-O in it is re-signed with that identity
# and the hardened runtime (QEMU keeps its entitlements: hypervisor, audio input), and the tarball is packed again.
if [ "${MYLINUX_RELEASE:-0}" = 1 ]; then
  TARBALL="out/qemu-runtime-macos-arm64.tar.gz"; TNAME=$(basename "$TARBALL"); WANT=$(cat tools/qemu-runtime.version)
  [ -f "$TARBALL" ] && [ -f "$TARBALL.sha256" ] || { echo "MYLINUX_RELEASE=1 needs $TARBALL and its .sha256 (tools/build-qemu-runtime.sh)" >&2; exit 1; }
  HAVE=$(tar -xzOf "$TARBALL" qemu-runtime/RUNTIME-REVISION 2>/dev/null | tr -d '\n')
  [ "$HAVE" = "$WANT" ] || { echo "$TARBALL is $HAVE, tools/qemu-runtime.version says $WANT: rebuild the runtime first" >&2; exit 1; }
  RT="$REPO/$NEW/Contents/Resources/runtime"
  if [ "$HARDENED" = 1 ]; then
    RS=$(mktemp -d "${TMPDIR:-/tmp}/mylinux-runtime-sign.XXXXXX")
    tar -xzf "$TARBALL" -C "$RS"
    find "$RS/qemu-runtime" -type f | while read -r f; do
      file -b "$f" | grep -q 'Mach-O' || continue
      case "$f" in
        */bin/qemu-system-aarch64)
          ENT="$RS/qemu.entitlements"; codesign -d --entitlements - --xml "$f" > "$ENT" 2>/dev/null
          [ -s "$ENT" ] || { echo "QEMU in the runtime has no entitlements to carry over" >&2; exit 1; }
          sign --entitlements "$ENT" "$f" >/dev/null 2>&1 || { echo "could not re-sign $(basename "$f")" >&2; exit 1; } ;;
        *) sign "$f" >/dev/null 2>&1 || { echo "could not re-sign $(basename "$f")" >&2; exit 1; } ;;
      esac
    done || exit 1
    "$RS/qemu-runtime/bin/qemu-system-aarch64" --version >/dev/null || { echo "the re-signed QEMU does not run" >&2; exit 1; }
    codesign -dv "$RS/qemu-runtime/bin/qemu-system-aarch64" 2>&1 | grep -q 'flags=.*runtime' || { echo "the re-signed QEMU has no hardened runtime" >&2; exit 1; }
    (cd "$RS" && COPYFILE_DISABLE=1 tar -czf "$RT/$TNAME" --uid 0 --gid 0 --no-xattrs qemu-runtime)
    (cd "$RT" && shasum -a 256 "$TNAME" > "$TNAME.sha256")
    rm -rf "$RS"
    echo "carrying the QEMU runtime $WANT, re-signed with the Developer ID"
  else
    cp "$TARBALL" "$TARBALL.sha256" "$RT/"
    echo "carrying the QEMU runtime $WANT"
  fi
fi

# the launcher's version: from the v* tags (the runtime has tags of its own), without the v
VERSION=$(git -C "$REPO" describe --tags --match 'v*' --always 2>/dev/null | sed 's/^v//'); [ -n "$VERSION" ] || VERSION=0.1
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
  <!-- mylinux-launcher://start: what the myLinux app in the Dock sends when clicked;
       mylinux://vnc/<name>, mylinux://ssh/<name>: open a remote machine (Shortcuts, scripts, open(1)) -->
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>dev.mylinux.launcher</string>
    <key>CFBundleURLSchemes</key><array><string>mylinux-launcher</string><string>mylinux</string></array>
  </dict></array>
  <!-- run.sh places the machine window through System Events (osascript); this text is macOS's permission prompt -->
  <key>NSAppleEventsUsageDescription</key><string>myLinux Launcher moves a machine's window onto the display it was sized for.</string>
$( [ "${MYLINUX_RELEASE:-0}" = 1 ] || printf '  <!-- the checkout this was built from; offered as the developer checkout when it is still there -->\n  <key>MyLinuxRepo</key><string>%s</string>\n' "$REPO" )
</dict></plist>
PLIST

for lib in "$NEW"/Contents/Frameworks/*.dylib; do sign "$lib" >/dev/null 2>&1 || echo "warning: could not sign $(basename "$lib")" >&2; done
sign --entitlements mac/launcher.entitlements "$NEW" >/dev/null 2>&1 || echo "warning: could not sign the app" >&2
codesign --verify --strict "$NEW" >/dev/null 2>&1 || echo "warning: the app's signature does not verify" >&2
[ "$IDENTITY" = - ] && echo "signed ad hoc (no signing certificate)" || echo "signed with: $IDENTITY$([ "$HARDENED" = 1 ] && echo ', hardened runtime')"
rm -rf "$APP"
mv "$NEW" "$APP"
echo "$APP ready"

if [ "${1:-}" = --install ]; then
  rm -rf "/Applications/myLinux Launcher.app"
  cp -R "$APP" /Applications/
  echo "installed /Applications/myLinux Launcher.app"
fi
