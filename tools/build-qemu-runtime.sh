#!/bin/sh
# Build the accelerated QEMU runtime and pack it for a release: QEMU 11.1.1 with VirGL (virglrenderer + ANGLE, so the
# guest's OpenGL runs on the Mac's GPU through Metal), self-contained, ad hoc signed with the hypervisor entitlement.
# The build itself is Try Omarchy's (https://github.com/omacom/try-omarchy, MIT): a pinned commit of that repository
# is checked out and its `make runtime` run, which downloads checksum-pinned sources and applies its QEMU patches.
# Usage: tools/build-qemu-runtime.sh [--from <try-omarchy checkout>] [--install]
#   --from     use an existing checkout at the pinned commit (its built runtime is reused when current)
#   --install  also install the result into $MYLINUX_OUT/qemu-runtime (default out/), as get-qemu-runtime.sh would
# Result: out/qemu-runtime-macos-arm64.tar.gz + .sha256, to attach to a release of the public assets repository
# named in tools/qemu-runtime.version:
#   gh release create "$(cat tools/qemu-runtime.version)" --repo adminmylinux/mylinux-releases --latest=false out/qemu-runtime-macos-arm64.tar.gz*
# (--latest=false: get-image.sh takes the repository's "latest" release for the image, which must stay a v* release)
# Needs Xcode's command line tools, python3, and what `make doctor` in that checkout asks for.
set -eu
cd "$(dirname "$0")/.."
REPO=$PWD
UPSTREAM=https://github.com/omacom/try-omarchy
COMMIT=58cbac574f9b6ab7454cee9771c752f5e48bce8e
VERSION=$(cat tools/qemu-runtime.version)
FROM=""; INSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=${2:?--from needs a directory}; shift 2 ;;
    --install) INSTALL=1; shift ;;
    *) echo "usage: tools/build-qemu-runtime.sh [--from <try-omarchy checkout>] [--install]" >&2; exit 64 ;;
  esac
done
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "the runtime is built on an Apple-silicon Mac" >&2; exit 1; }

if [ -z "$FROM" ]; then
  FROM="$REPO/out/qemu-runtime-build/try-omarchy"
  if [ ! -d "$FROM/.git" ]; then mkdir -p "$(dirname "$FROM")"; git clone -q "$UPSTREAM" "$FROM"; fi
  git -C "$FROM" fetch -q origin "$COMMIT" 2>/dev/null || git -C "$FROM" fetch -q origin
  git -C "$FROM" checkout -q --detach "$COMMIT"
fi
FROM=$(cd "$FROM" && pwd)
HEAD=$(git -C "$FROM" rev-parse HEAD)
[ "$HEAD" = "$COMMIT" ] || { echo "$FROM is at $HEAD, not the pinned $COMMIT" >&2; exit 1; }
# local edits outside macos/ (a guest experiment, say) do not reach the runtime; edits to its inputs would
[ -z "$(git -C "$FROM" status --porcelain -- macos scripts Makefile)" ] || { echo "$FROM has local changes to the runtime's inputs" >&2; exit 1; }
# Our own patches (tools/qemu-runtime-patches/*.patch, applied after theirs) ride along for the build: copied into
# their patches folder, where the build cache sees them, and applied by one extra line in their script. Both are
# undone afterwards, so the checkout is back at the pinned commit.
THEIRS="$FROM/macos/build-qemu-gpu-runtime.sh"
restore() { git -C "$FROM" checkout -q -- macos/build-qemu-gpu-runtime.sh; rm -f "$FROM"/macos/patches/mylinux-*.patch; }
trap restore EXIT
for P in "$REPO"/tools/qemu-runtime-patches/*.patch; do
  [ -f "$P" ] || continue
  NAME="mylinux-$(basename "$P")"
  cp "$P" "$FROM/macos/patches/$NAME"
  python3 - "$THEIRS" "$NAME" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p).read()
anchor = 'patch -d "$source_dir" -p1 -f -i "$pinch_patch"\n'
assert anchor in s, "their build script no longer applies the pinch patch where expected"
line = 'patch -d "$source_dir" -p1 -f -i "$native_dir/patches/%s"\n' % name
if line not in s: s = s.replace(anchor, anchor + line, 1)
open(p, 'w').write(s)
PY
done
make -C "$FROM" runtime
BUILT="$FROM/macos/.build/qemu-gpu-runtime"
[ -x "$BUILT/bin/qemu-system-aarch64" ] || { echo "the build left no runtime in $BUILT" >&2; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/qemu-runtime.XXXXXX"); trap 'rm -rf "$STAGE"; restore' EXIT
R="$STAGE/qemu-runtime"
mkdir -p "$R/bin" "$R/source/patches"
cp "$BUILT/bin/qemu-system-aarch64" "$R/bin/"
cp "$BUILT/bin/zstd" "$R/bin/"          # run-omarchy.sh unpacks the Omarchy root disk with it (no Homebrew needed)
# debugfs from e2fsprogs (GPL-2.0; libext2fs LGPL-2.0), built here from the pinned source and linked with nothing but
# libSystem: tools/omarchy-bake-session.sh writes the session tool into a fresh Omarchy disk with it.
E2FS_VERSION=1.47.4
E2FS_URL="https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FS_VERSION/e2fsprogs-$E2FS_VERSION.tar.xz"
E2FS_SHA256=fd5bf388cbdbe006a3d3b318d983b2948382440acc85a87f1e7d108653e8db0b
mkdir -p out/.cache; E2FS_TAR="out/.cache/e2fsprogs-$E2FS_VERSION.tar.xz"
[ -f "$E2FS_TAR" ] || curl -fL --progress-bar -o "$E2FS_TAR.new" "$E2FS_URL" && { [ -f "$E2FS_TAR" ] || mv "$E2FS_TAR.new" "$E2FS_TAR"; }
[ "$(shasum -a 256 "$E2FS_TAR" | cut -d' ' -f1)" = "$E2FS_SHA256" ] || { echo "e2fsprogs-$E2FS_VERSION.tar.xz does not match its pinned checksum" >&2; exit 1; }
mkdir -p "$STAGE/e2fsprogs" && tar -xJf "$E2FS_TAR" -C "$STAGE/e2fsprogs" --strip-components=1
( cd "$STAGE/e2fsprogs" && ./configure --disable-nls --disable-testio-debug --disable-uuidd --disable-fuse2fs > configure.log 2>&1 \
  && make -j"$(sysctl -n hw.ncpu)" libs > make.log 2>&1 && make -j"$(sysctl -n hw.ncpu)" -C debugfs >> make.log 2>&1 ) \
  || { echo "e2fsprogs did not build (see $STAGE/e2fsprogs/*.log)" >&2; trap - EXIT; restore; exit 1; }
cp "$STAGE/e2fsprogs/debugfs/debugfs" "$R/bin/debugfs"
otool -L "$R/bin/debugfs" | grep -q '/opt/homebrew' && { echo "debugfs links against Homebrew libraries" >&2; exit 1; }
codesign --force -s - "$R/bin/debugfs" 2>/dev/null || true
cp "$STAGE/e2fsprogs/NOTICE" "$R/source/NOTICE.e2fsprogs"
cp -R "$BUILT/lib" "$R/lib"
printf '%s\n' "$VERSION" > "$R/RUNTIME-REVISION"
# what QEMU's GPL asks of whoever passes the binary on: the exact source. The patches travel with it, the pinned
# upstream archives are named with their checksums (the build script is the authority on those).
cp "$FROM"/macos/patches/*.patch "$R/source/patches/"     # theirs and ours (mylinux-*.patch, still in place here)
cp "$FROM/macos/build-qemu-gpu-runtime.sh" "$FROM/macos/prepare-qemu-gpu-runtime.sh" "$FROM/macos/pinned-runtime-bottles.sh" "$R/source/"
cp "$FROM/LICENSE" "$R/source/LICENSE.try-omarchy"
cp "$FROM/THIRD_PARTY_NOTICES.md" "$R/source/THIRD_PARTY_NOTICES.try-omarchy.md"
{
  echo "# myLinux accelerated QEMU runtime $VERSION"
  echo
  echo "QEMU (GPL-2.0 and other component licences) with virglrenderer (MIT), ANGLE (BSD-3-Clause), libepoxy (MIT),"
  echo "libslirp (BSD-3-Clause), SDL (zlib), pixman (MIT), GLib (LGPL-2.1-or-later, linked dynamically), PCRE2 (BSD),"
  echo "gettext's libintl (LGPL), lz4 (BSD-2-Clause), xz's liblzma (0BSD), zstd (BSD-3-Clause)."
  echo "bin/debugfs is from e2fsprogs $E2FS_VERSION (GPL-2.0, libext2fs LGPL-2.0; source/NOTICE.e2fsprogs), built unchanged from"
  echo "    $E2FS_URL"
  echo "    sha256 $E2FS_SHA256"
  echo "with: ./configure --disable-nls --disable-testio-debug --disable-uuidd --disable-fuse2fs && make libs && make -C debugfs"
  echo
  echo "Built with Try Omarchy's runtime build, $UPSTREAM at commit $COMMIT (MIT):"
  echo "source/build-qemu-gpu-runtime.sh is the recipe, source/patches/ are the changes applied to QEMU and libslirp;"
  echo "the mylinux-*.patch files among them are myLinux's own, applied after theirs (the recipe line for each is"
  echo "inserted after the pinch-zoom patch)."
  echo "The upstream sources it downloads, by checksum:"
  echo
  grep -E '^(qemu_commit|qemu_url|qemu_sha256|slirp_url|slirp_sha256|virgl_url|virgl_sha256|angle_url|angle_sha256|epoxy_url|epoxy_sha256)=' "$FROM/macos/build-qemu-gpu-runtime.sh" | sed 's/^/    /'
} > "$R/NOTICES.md"
"$R/bin/qemu-system-aarch64" --version >/dev/null || { echo "the packed runtime does not run" >&2; exit 1; }
"$R/bin/debugfs" -V >/dev/null 2>&1 || { echo "the packed debugfs does not run" >&2; exit 1; }

mkdir -p out
TAR="out/qemu-runtime-macos-arm64.tar.gz"
# sorted names and fixed owners, so the same build packs to the same listing; the Mach-O signatures are inside the files
(cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf "$REPO/$TAR.new" --uid 0 --gid 0 --no-xattrs qemu-runtime)
mv -f "$TAR.new" "$TAR"
(cd out && shasum -a 256 "$(basename "$TAR")" > "$(basename "$TAR").sha256")
echo "packed $TAR ($(du -h "$TAR" | cut -f1)), release tag $VERSION"
if [ "$INSTALL" = 1 ]; then MYLINUX_RUNTIME_FILE="$REPO/$TAR" sh tools/get-qemu-runtime.sh; fi
