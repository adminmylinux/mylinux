#!/bin/sh
# Which QEMU starts the machines: prints "runtime" (the accelerated one in <out>/qemu-runtime, installed by
# tools/get-qemu-runtime.sh) or "brew" (Homebrew's). Usage: tools/qemu-flavour.sh <out dir>
# MYLINUX_QEMU=brew|runtime overrides; asking for a runtime that is not there is an error.
set -eu
OUT="${1:?usage: qemu-flavour.sh <out dir>}"
HAVE=0; [ -x "$OUT/qemu-runtime/bin/qemu-system-aarch64" ] && [ -d "$OUT/qemu-runtime/lib" ] && HAVE=1
case "${MYLINUX_QEMU:-auto}" in
  brew) echo brew ;;
  runtime) [ "$HAVE" = 1 ] || { echo "MYLINUX_QEMU=runtime, but $OUT/qemu-runtime is missing: run tools/get-qemu-runtime.sh" >&2; exit 1; }; echo runtime ;;
  auto) if [ "$HAVE" = 1 ]; then echo runtime; else echo brew; fi ;;
  *) echo "MYLINUX_QEMU must be brew, runtime or auto" >&2; exit 1 ;;
esac
