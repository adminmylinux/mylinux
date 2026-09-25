#!/bin/sh
# Publishes a DMG from mac/release.sh to adminmylinux/mylinux-releases, twice:
#   launcher-<version>  this version, kept (created --latest=false: the repository's "latest" is the Linux image,
#                       which tools/get-image.sh resolves)
#   launcher-latest     always the newest launcher, so a link never needs changing:
#                       https://github.com/adminmylinux/mylinux-releases/releases/download/launcher-latest/myLinux-Launcher.dmg
# Both carry the stable asset name myLinux-Launcher.dmg (+ .sha256).
# Usage: mac/publish-release.sh NOTES_FILE   (the version comes from the v* tag, as in mac/release.sh)
set -eu
cd "$(dirname "$0")/.."
REPO=adminmylinux/mylinux-releases
NOTES=${1:?usage: mac/publish-release.sh NOTES_FILE}
VERSION=$(git describe --tags --match 'v*' --exact-match 2>/dev/null | sed 's/^v//')
[ -n "$VERSION" ] || { echo "HEAD has no v* tag: tag the release first" >&2; exit 1; }
SRC="out/mac/myLinux-Launcher-$VERSION.dmg"
[ -f "$SRC" ] || { echo "no $SRC: run mac/release.sh --notarize <profile> first" >&2; exit 1; }
xcrun stapler validate "$SRC" >/dev/null || { echo "$SRC is not notarised" >&2; exit 1; }

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
cp "$SRC" "$STAGE/myLinux-Launcher.dmg"
(cd "$STAGE" && shasum -a 256 myLinux-Launcher.dmg > myLinux-Launcher.dmg.sha256)

# this version
if gh release view "launcher-$VERSION" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "launcher-$VERSION" -R "$REPO" --clobber "$STAGE/myLinux-Launcher.dmg" "$STAGE/myLinux-Launcher.dmg.sha256"
  gh release edit "launcher-$VERSION" -R "$REPO" --notes-file "$NOTES"
else
  gh release create "launcher-$VERSION" -R "$REPO" --latest=false --title "myLinux Launcher $VERSION" \
    --notes-file "$NOTES" "$STAGE/myLinux-Launcher.dmg" "$STAGE/myLinux-Launcher.dmg.sha256"
fi

# the newest: new files go up under a temporary name and are renamed over the old ones, so the link is never broken
LATEST=launcher-latest
{ echo "Always the newest myLinux Launcher: currently **$VERSION** (the same files as [launcher-$VERSION](https://github.com/$REPO/releases/tag/launcher-$VERSION))."
  echo; cat "$NOTES"; } > "$STAGE/latest-notes.md"
if ! gh release view "$LATEST" -R "$REPO" >/dev/null 2>&1; then
  gh release create "$LATEST" -R "$REPO" --latest=false --title "myLinux Launcher (latest: $VERSION)" \
    --notes-file "$STAGE/latest-notes.md" "$STAGE/myLinux-Launcher.dmg" "$STAGE/myLinux-Launcher.dmg.sha256"
else
  for f in myLinux-Launcher.dmg myLinux-Launcher.dmg.sha256; do cp "$STAGE/$f" "$STAGE/new-$f"; done
  gh release upload "$LATEST" -R "$REPO" --clobber "$STAGE/new-myLinux-Launcher.dmg" "$STAGE/new-myLinux-Launcher.dmg.sha256"
  ID=$(gh api "repos/$REPO/releases/tags/$LATEST" --jq .id)
  for f in myLinux-Launcher.dmg myLinux-Launcher.dmg.sha256; do
    old=$(gh api "repos/$REPO/releases/$ID/assets" --jq ".[] | select(.name == \"$f\") | .id")
    new=$(gh api "repos/$REPO/releases/$ID/assets" --jq ".[] | select(.name == \"new-$f\") | .id")
    [ -z "$old" ] || gh api -X DELETE "repos/$REPO/releases/assets/$old" >/dev/null
    gh api -X PATCH "repos/$REPO/releases/assets/$new" -f name="$f" >/dev/null
  done
  gh release edit "$LATEST" -R "$REPO" --title "myLinux Launcher (latest: $VERSION)" --notes-file "$STAGE/latest-notes.md"
fi

# check what a visitor gets
URL="https://github.com/$REPO/releases/download/$LATEST/myLinux-Launcher.dmg"
GOT=$(curl -fsSL "$URL.sha256" | cut -d' ' -f1); WANT=$(cut -d' ' -f1 "$STAGE/myLinux-Launcher.dmg.sha256")
[ "$GOT" = "$WANT" ] || { echo "the latest link serves $GOT, expected $WANT" >&2; exit 1; }
echo "published $VERSION: https://github.com/$REPO/releases/tag/launcher-$VERSION"
echo "latest link: $URL"
