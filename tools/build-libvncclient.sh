#!/bin/sh
# Build libvncclient with libjpeg-turbo and OpenSSL for the launcher, from pinned sources, for macOS 15 and later:
# Homebrew's bottles are built for the macOS they were installed on and refuse to load on an older one, so a release
# of the launcher bundles these instead (mac/build-app.sh prefers out/libvnc when it is there). Once per checkout;
# about five minutes, most of it OpenSSL. Needs cmake and Xcode's command line tools.
# Usage: tools/build-libvncclient.sh            -> out/libvnc/{lib,include,lib/pkgconfig}
#        tools/build-libvncclient.sh --remove   -> back to Homebrew's libvncserver for local builds
set -eu
cd "$(dirname "$0")/.."
OUT="${MYLINUX_OUT:-out}"; PREFIX=$(cd "$OUT" 2>/dev/null && pwd)/libvnc || { mkdir -p "$OUT"; PREFIX=$(cd "$OUT" && pwd)/libvnc; }
if [ "${1:-}" = --remove ]; then rm -rf "$PREFIX"; echo "removed $PREFIX"; exit 0; fi
TARGET=15.0
OPENSSL_VERSION=3.5.8
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SHA256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
JPEG_VERSION=3.2.0
JPEG_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/libjpeg-turbo-$JPEG_VERSION.tar.gz"
JPEG_SHA256=6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
VNC_VERSION=0.9.15
VNC_URL="https://github.com/LibVNC/libvncserver/archive/refs/tags/LibVNCServer-$VNC_VERSION.tar.gz"
VNC_SHA256=62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7
command -v cmake >/dev/null || { echo "cmake is needed (brew install cmake)" >&2; exit 1; }
xcode-select -p >/dev/null 2>&1 || { echo "Xcode's command line tools are needed (xcode-select --install)" >&2; exit 1; }
CACHE="$OUT/.cache"; mkdir -p "$CACHE"
fetch() { # name url sha256
  f="$CACHE/$1"
  [ -f "$f" ] || { echo "downloading $1 ..."; curl -fL --progress-bar -o "$f.new" "$2" && mv "$f.new" "$f"; }
  [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$3" ] || { echo "$1 does not match its pinned checksum" >&2; exit 1; }
}
fetch "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_URL" "$OPENSSL_SHA256"
fetch "libjpeg-turbo-$JPEG_VERSION.tar.gz" "$JPEG_URL" "$JPEG_SHA256"
fetch "libvncserver-$VNC_VERSION.tar.gz" "$VNC_URL" "$VNC_SHA256"
W=$(mktemp -d "${TMPDIR:-/tmp}/libvnc-build.XXXXXX"); trap 'rm -rf "$W"' EXIT
NEW="$PREFIX.new"; rm -rf "$NEW"; mkdir -p "$NEW"
export MACOSX_DEPLOYMENT_TARGET=$TARGET
JOBS=$(sysctl -n hw.ncpu)

echo "building OpenSSL $OPENSSL_VERSION ..."
mkdir -p "$W/openssl" && tar -xzf "$CACHE/openssl-$OPENSSL_VERSION.tar.gz" -C "$W/openssl" --strip-components=1
( cd "$W/openssl" && ./Configure darwin64-arm64-cc --prefix="$NEW" --libdir=lib shared no-tests no-docs no-apps no-legacy > configure.log 2>&1 \
  && make -j"$JOBS" > make.log 2>&1 && make install_sw > install.log 2>&1 ) || { tail -20 "$W/openssl/make.log" "$W/openssl/configure.log" >&2; echo "OpenSSL did not build" >&2; exit 1; }

echo "building libjpeg-turbo $JPEG_VERSION ..."
mkdir -p "$W/jpeg" && tar -xzf "$CACHE/libjpeg-turbo-$JPEG_VERSION.tar.gz" -C "$W/jpeg" --strip-components=1
( cd "$W/jpeg" && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$NEW" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$TARGET -DCMAKE_INSTALL_NAME_DIR="$NEW/lib" -DENABLE_STATIC=0 -DWITH_TURBOJPEG=0 -DWITH_JPEG8=1 > cmake.log 2>&1 \
  && cmake --build build -j"$JOBS" > make.log 2>&1 && cmake --install build > install.log 2>&1 ) || { tail -20 "$W/jpeg/cmake.log" "$W/jpeg/make.log" >&2; echo "libjpeg-turbo did not build" >&2; exit 1; }

echo "building libvncclient $VNC_VERSION ..."
mkdir -p "$W/vnc" && tar -xzf "$CACHE/libvncserver-$VNC_VERSION.tar.gz" -C "$W/vnc" --strip-components=1
( cd "$W/vnc" && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$NEW" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$TARGET -DCMAKE_INSTALL_NAME_DIR="$NEW/lib" -DCMAKE_PREFIX_PATH="$NEW" -DOPENSSL_ROOT_DIR="$NEW" \
    -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF -DWITH_GCRYPT=OFF -DWITH_JPEG=ON -DWITH_PNG=OFF -DWITH_SDL=OFF -DWITH_LZO=OFF -DWITH_SASL=OFF \
    -DWITH_SYSTEMD=OFF -DWITH_FFMPEG=OFF -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF -DWITH_QT=OFF -DWITH_WEBSOCKETS=OFF -DWITH_GTK=OFF -DWITH_XCB=OFF -DWITH_LIBSSHTUNNEL=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 > cmake.log 2>&1 \
  && cmake --build build -j"$JOBS" > make.log 2>&1 && cmake --install build > install.log 2>&1 ) || { tail -20 "$W/vnc/cmake.log" "$W/vnc/make.log" >&2; echo "libvncserver did not build" >&2; exit 1; }

# the checks a release relies on: the client library links its own OpenSSL and jpeg, and everything is for macOS $TARGET
LIB="$NEW/lib/libvncclient.1.dylib"; [ -f "$LIB" ] || { echo "no libvncclient in $NEW/lib" >&2; exit 1; }
otool -L "$LIB" | grep -q "$NEW/lib/libssl" || { echo "libvncclient did not link OpenSSL (no TLS)" >&2; otool -L "$LIB" >&2; exit 1; }
otool -L "$LIB" | grep -q "$NEW/lib/libjpeg" || { echo "libvncclient did not link libjpeg" >&2; otool -L "$LIB" >&2; exit 1; }
for f in "$NEW"/lib/*.dylib; do
  m=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  [ "$m" = "$TARGET" ] || { echo "$(basename "$f") is built for macOS $m, not $TARGET" >&2; exit 1; }
done
rm -rf "$NEW/bin" "$NEW/share" "$NEW/ssl"    # only the libraries, headers and pkg-config files are used
# the pkg-config files name the prefix they were built into; make them name where they end up
for pc in "$NEW"/lib/pkgconfig/*.pc; do sed -i '' "s|$NEW|$PREFIX|g" "$pc"; done
for f in "$NEW"/lib/*.dylib; do
  install_name_tool -id "$(otool -D "$f" | tail -1 | sed "s|$NEW|$PREFIX|")" "$f" 2>/dev/null
  for dep in $(otool -L "$f" | awk -v p="$NEW" 'index($1, p) == 1 { print $1 }'); do install_name_tool -change "$dep" "$(printf '%s' "$dep" | sed "s|$NEW|$PREFIX|")" "$f" 2>/dev/null; done
  codesign --force --sign - "$f" >/dev/null 2>&1
done
rm -rf "$PREFIX"; mv "$NEW" "$PREFIX"
{
  echo "libvncclient $VNC_VERSION (GPL-2.0-or-later; LibVNC/libvncserver), libjpeg-turbo $JPEG_VERSION (IJG and BSD-3-Clause),"
  echo "OpenSSL $OPENSSL_VERSION (Apache-2.0), built by tools/build-libvncclient.sh for macOS $TARGET from:"
  echo "  $OPENSSL_URL  sha256 $OPENSSL_SHA256"
  echo "  $JPEG_URL  sha256 $JPEG_SHA256"
  echo "  $VNC_URL  sha256 $VNC_SHA256"
} > "$PREFIX/NOTICES.txt"
echo "ok: $PREFIX (libvncclient $VNC_VERSION, libjpeg-turbo $JPEG_VERSION, OpenSSL $OPENSSL_VERSION, macOS $TARGET+)"
