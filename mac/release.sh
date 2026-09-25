#!/bin/sh
# A launcher release for other Macs: the app with the QEMU runtime inside, signed with a Developer ID, notarised,
# in a DMG: out/mac/myLinux-Launcher-<version>.dmg (+ .sha256), ready for a release in adminmylinux/mylinux-releases.
# Usage: mac/release.sh [--sign IDENTITY] [--notarize PROFILE] [--unsigned]
#   --sign        default: the one "Developer ID Application: ..." identity in the login keychain
#   --notarize    the notarytool keychain profile (xcrun notarytool store-credentials <name> ...); without it the
#                 DMG is signed but not notarised, and macOS shows the "cannot verify" dialog on other Macs
#   --unsigned    ad hoc: for trying the packaging on this Mac only
# Needs out/qemu-runtime-macos-arm64.tar.gz at the version in tools/qemu-runtime.version (tools/build-qemu-runtime.sh).
set -eu
cd "$(dirname "$0")/.."
IDENTITY=""; PROFILE=""; UNSIGNED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) IDENTITY=${2:?}; shift 2 ;;
    --notarize) PROFILE=${2:?}; shift 2 ;;
    --unsigned) UNSIGNED=1; shift ;;
    *) echo "usage: mac/release.sh [--sign IDENTITY] [--notarize PROFILE] [--unsigned]" >&2; exit 64 ;;
  esac
done
if [ "$UNSIGNED" = 1 ]; then IDENTITY=-
elif [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [ -n "$IDENTITY" ] || { echo "no Developer ID Application identity in the keychain: pass --sign, or --unsigned for a local try" >&2; exit 1; }
fi
MYLINUX_RELEASE=1 MYLINUX_SIGN_IDENTITY="$IDENTITY" mac/build-app.sh
APP="out/mac/myLinux Launcher.app"
VERSION=$(git describe --tags --match 'v*' --always 2>/dev/null | sed 's/^v//'); [ -n "$VERSION" ] || VERSION=0.1
DMG="$PWD/out/mac/myLinux-Launcher-$VERSION.dmg"
set -- "$PWD/$APP" "$DMG"
[ "$IDENTITY" = - ] || set -- --sign "$IDENTITY" "$@"
[ -z "$PROFILE" ] || set -- --notarize "$PROFILE" "$@"
mac/package-dmg.sh "$@"
