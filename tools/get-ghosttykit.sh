#!/bin/sh
# GhosttyKit (github.com/Lakr233/libghostty-spm, MIT): Ghostty's terminal as a Swift package, the launcher's opt-in
# terminal (Settings › Terminal). Its binary target is a 77 MB XCFramework that SwiftPM's own downloader fetched too
# slowly to finish here, so this fetches the pinned release with curl instead, checks both files against pinned
# SHA-256 sums (the XCFramework's is the one the package itself declares), and unpacks them into
# out/ghosttykit/libghostty-spm with the binary target pointing at the local copy. mac/Package.swift uses that path;
# mac/build-app.sh runs this first. Nothing is fetched when the pinned version is already there.
# Usage: tools/get-ghosttykit.sh
set -eu
cd "$(dirname "$0")/.."
VERSION=1.6.20260922
PATCHED="$VERSION+mylinux2"      # this script's changes to the package, below: bump it when they change
SRC_URL="https://github.com/Lakr233/libghostty-spm/archive/refs/tags/$VERSION.tar.gz"
SRC_SHA256=0cb7946b582c51a969224be6aa3c4df9e4309a9a35f2f3e35d470ede920e9a1e
XCF_URL="https://github.com/Lakr233/libghostty-spm/releases/download/upstream.3c47ca159368-2/GhosttyKit.xcframework.zip"
XCF_SHA256=804d4c92cad153eb8d85ed86f4c98ca587e90ff47ac0a62c846c985ece02a9c3
DEST=out/ghosttykit/libghostty-spm
if [ "$(cat "$DEST/.mylinux-version" 2>/dev/null)" = "$PATCHED" ] && [ -d "$DEST/GhosttyKit.xcframework" ]; then exit 0; fi
FETCH="--retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20"
STAGE=out/ghosttykit/.staging; rm -rf "$STAGE"; mkdir -p "$STAGE"; trap 'rm -rf "$STAGE"' EXIT
echo "downloading GhosttyKit $VERSION ..."
# shellcheck disable=SC2086
curl -fsSL $FETCH -o "$STAGE/src.tar.gz" "$SRC_URL"
# shellcheck disable=SC2086
curl -fL $FETCH --progress-bar -o "$STAGE/xcf.zip" "$XCF_URL"
[ "$(shasum -a 256 "$STAGE/src.tar.gz" | cut -d' ' -f1)" = "$SRC_SHA256" ] || { echo "GhosttyKit source does not match its pinned checksum" >&2; exit 1; }
[ "$(shasum -a 256 "$STAGE/xcf.zip" | cut -d' ' -f1)" = "$XCF_SHA256" ] || { echo "GhosttyKit.xcframework does not match its pinned checksum" >&2; exit 1; }
tar -xzf "$STAGE/src.tar.gz" -C "$STAGE"
PKG="$STAGE/libghostty-spm-$VERSION"
ditto -x -k "$STAGE/xcf.zip" "$PKG"
[ -d "$PKG/GhosttyKit.xcframework" ] || { echo "the zip holds no GhosttyKit.xcframework" >&2; ls "$PKG" >&2; exit 1; }
# the binary target from the local copy instead of the URL (same file, checked above)
perl -0pi -e 's/\.binaryTarget\(\s*name: "libghostty",\s*url: "[^"]*",\s*checksum: "[0-9a-f]*"\s*\)/.binaryTarget(name: "libghostty", path: "GhosttyKit.xcframework")/' "$PKG/Package.swift"
grep -q 'path: "GhosttyKit.xcframework"' "$PKG/Package.swift" || { echo "could not point Package.swift at the local XCFramework" >&2; exit 1; }
# the surface handle public: the launcher reads the screen and scrollback through Ghostty's C API
# (ghostty_surface_read_text) for Open Last URL, which the Swift wrapper has no call for
perl -pi -e 's/^    var rawValue: ghostty_surface_t\? \{/    public var rawValue: ghostty_surface_t? {/' "$PKG/Sources/GhosttyTerminal/Surface/TerminalSurface.swift"
grep -q 'public var rawValue: ghostty_surface_t?' "$PKG/Sources/GhosttyTerminal/Surface/TerminalSurface.swift" || { echo "could not make TerminalSurface.rawValue public" >&2; exit 1; }
# its resources from the app's Contents/Resources: SwiftPM's Bundle.module looks beside Contents (where nothing may
# sit in a signed app) or in the build folder, and stops the app when neither is there
R="$PKG/Sources/GhosttyTerminal/Configuration/GhosttyRuntimeResources.swift"
perl -0pi -e 's/public enum GhosttyRuntimeResources \{\n/public enum GhosttyRuntimeResources {\n    \/\/ myLinux: the app bundle'"'"'s Contents\/Resources first (mac\/build-app.sh copies the bundle there)\n    static var bundle: Bundle {\n        Bundle.main.resourceURL.flatMap { Bundle(url: \$0.appendingPathComponent("GhosttyKit_GhosttyTerminal.bundle")) } ?? Bundle.module\n    }\n\n/; s/Bundle\.module\.url\(/GhosttyRuntimeResources.bundle.url(/g' "$R"
[ "$(grep -c 'GhosttyRuntimeResources.bundle.url(' "$R")" = 2 ] || { echo "could not point GhosttyKit at Contents/Resources" >&2; exit 1; }
printf '%s\n' "$PATCHED" > "$PKG/.mylinux-version"
rm -rf "$DEST"; mv "$PKG" "$DEST"
echo "ok: $DEST (GhosttyKit $VERSION)"
