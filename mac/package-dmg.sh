#!/bin/sh
# Put a built launcher app into a DMG with an Applications shortcut, and (with a real signing identity) sign it,
# have Apple notarise the app and the DMG, and staple both tickets, so the download opens on any Mac without warnings.
# Usage: mac/package-dmg.sh [--sign IDENTITY] [--notarize PROFILE] <app> <out.dmg>
#   --sign IDENTITY      "Developer ID Application: ..." (the app must already be signed with it, mac/build-app.sh does that)
#   --notarize PROFILE   a `xcrun notarytool store-credentials` keychain profile; implies --sign
# Without --sign the DMG is unsigned and only good for this Mac (Gatekeeper asks for right-click > Open elsewhere).
set -eu
IDENTITY=""; PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) IDENTITY=${2:?--sign needs an identity}; shift 2 ;;
    --notarize) PROFILE=${2:?--notarize needs a keychain profile}; shift 2 ;;
    --) shift; break ;;
    -*) echo "usage: mac/package-dmg.sh [--sign IDENTITY] [--notarize PROFILE] <app> <out.dmg>" >&2; exit 64 ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || { echo "usage: mac/package-dmg.sh [--sign IDENTITY] [--notarize PROFILE] <app> <out.dmg>" >&2; exit 64; }
APP=$1; DMG=$2
[ -d "$APP" ] && [ -f "$APP/Contents/Info.plist" ] || { echo "$APP is not an app bundle" >&2; exit 2; }
case "$DMG" in *.dmg) ;; *) echo "the output must end in .dmg" >&2; exit 2 ;; esac
[ -z "$PROFILE" ] || [ -n "$IDENTITY" ] || { echo "--notarize needs --sign with a Developer ID Application identity" >&2; exit 2; }
NAME=$(basename "$APP" .app)
VOL=$NAME
W=$(mktemp -d "${TMPDIR:-/tmp}/mylinux-dmg.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/root"
# ditto keeps the signature, resource forks and symlinks of the bundle as they are
ditto "$APP" "$W/root/$NAME.app"
ln -s /Applications "$W/root/Applications"
codesign --verify --strict --deep "$W/root/$NAME.app" || { echo "the app's signature does not verify: nothing packaged" >&2; exit 1; }

# Apple's reasons for a rejection, one line each
notary_log() {
  ID=$(sed -n 's/^ *id: //p' "$1" | head -1); [ -n "$ID" ] || return 0
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for i in d.get("issues") or []: print("  " + i.get("severity", ""), i.get("path", ""), "-", i.get("message", ""))' >&2 || true
}
if [ -n "$PROFILE" ]; then
  # the app first: its own ticket is stapled into the bundle, so it verifies offline once dragged out of the DMG
  echo "notarising the app ..."
  ditto -c -k --keepParent "$W/root/$NAME.app" "$W/app.zip"
  xcrun notarytool submit "$W/app.zip" --keychain-profile "$PROFILE" --wait > "$W/notary-app.log" 2>&1 \
    || { cat "$W/notary-app.log" >&2; ID=$(sed -n 's/^ *id: //p' "$W/notary-app.log" | head -1); [ -z "$ID" ] || xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2; echo "notarisation of the app failed" >&2; exit 1; }
  grep -q 'status: Accepted' "$W/notary-app.log" || { cat "$W/notary-app.log" >&2; notary_log "$W/notary-app.log"; echo "the app was not accepted" >&2; exit 1; }
  xcrun stapler staple -q "$W/root/$NAME.app"
fi

rm -f "$DMG"
hdiutil create -quiet -volname "$VOL" -srcfolder "$W/root" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  codesign --verify --strict "$DMG"
fi
if [ -n "$PROFILE" ]; then
  echo "notarising the disk image ..."
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait > "$W/notary-dmg.log" 2>&1 \
    || { cat "$W/notary-dmg.log" >&2; echo "notarisation of the disk image failed" >&2; exit 1; }
  grep -q 'status: Accepted' "$W/notary-dmg.log" || { cat "$W/notary-dmg.log" >&2; notary_log "$W/notary-dmg.log"; echo "the disk image was not accepted" >&2; exit 1; }
  xcrun stapler staple -q "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | grep -q 'accepted' || { echo "Gatekeeper does not accept the stapled disk image" >&2; exit 1; }
fi
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG ready ($(du -h "$DMG" | cut -f1)), checksum in $DMG.sha256"
