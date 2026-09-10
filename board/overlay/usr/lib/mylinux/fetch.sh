# Verified downloads, sourced by apps-setup and apps-setup-ai. Reads /usr/share/mylinux/manifest.env: pinned URLs
# and sha256 sums (tools/manifest-update.sh refreshes them; the image ships the copy it was built with).
# fetch_verified URL SHA256 OUT: downloads to OUT.part, checks the sum when one is given, then moves it into place.
# An empty SHA256 means the upstream publishes no checksum (the Claude installer): the download is still staged
# and its exit status checked, and the caller says so in its output.
MANIFEST="${MANIFEST:-/usr/share/mylinux/manifest.env}"
[ -f "$MANIFEST" ] && . "$MANIFEST"
fetch_verified() {
  url="$1"; sum="$2"; out="$3"
  rm -f "$out.part"
  if ! curl -fL --progress-bar --retry 2 -o "$out.part" "$url"; then echo "download failed: $url" >&2; rm -f "$out.part"; return 1; fi
  if [ -n "$sum" ]; then
    got=$(sha256sum "$out.part" | cut -d' ' -f1)
    if [ "$got" != "$sum" ]; then echo "checksum mismatch for $url: got $got, manifest says $sum" >&2; rm -f "$out.part"; return 1; fi
  else
    echo "(no upstream checksum for $url: verified by TLS only)"
  fi
  mv -f "$out.part" "$out"
}
