#!/bin/sh
# The UEFI firmware the server machines (run-server.sh: Debian, Alpine) boot with: the edk2 build QEMU itself ships
# (pc-bios/edk2-aarch64-code.fd.bz2, BSD-2-Clause-Patent, with its licence file) from the QEMU commit the runtime is
# built from, pinned by checksum; the runtime carries no firmware of its own. Read-only flash for the guest; nothing
# from it runs on the Mac. (Debian's own AAVMF build stops after its banner on QEMU 11 under HVF, so it is not used.)
# Usage: tools/get-edk2.sh DIR   writes DIR/edk2-aarch64-code.fd and DIR/edk2-licenses.txt, or fails leaving neither
set -eu
DIR=${1:?usage: tools/get-edk2.sh DIR}
QEMU_COMMIT=c3d48b7d1e89604920e5b81b91140c2ad39a1943      # the runtime's QEMU (tools/build-qemu-runtime.sh)
EFI_URL="https://gitlab.com/qemu-project/qemu/-/raw/$QEMU_COMMIT/pc-bios/edk2-aarch64-code.fd.bz2"
EFI_SHA256=c023444108b7a132fdebf70c4765cd2dd9af2a9ff7d001a743aaabe87c20a458
EFI_LICENSE_URL="https://gitlab.com/qemu-project/qemu/-/raw/$QEMU_COMMIT/pc-bios/edk2-licenses.txt"
EFI_LICENSE_SHA256=1ddeaed2e7d2e9ecb960bdfc1b8ee45387aff70d056d985d145949af3951657c
mkdir -p "$DIR"
T="$DIR/.edk2"; rm -rf "$T"; mkdir -p "$T"; trap 'rm -rf "$T"' EXIT
echo "downloading the UEFI firmware (QEMU's edk2 build) ..."
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$T/edk2.fd.bz2" "$EFI_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$T/edk2-licenses.txt" "$EFI_LICENSE_URL"
[ "$(shasum -a 256 "$T/edk2.fd.bz2" | cut -d' ' -f1)" = "$EFI_SHA256" ] || { echo "the firmware does not match its pinned checksum: nothing installed" >&2; exit 1; }
[ "$(shasum -a 256 "$T/edk2-licenses.txt" | cut -d' ' -f1)" = "$EFI_LICENSE_SHA256" ] || { echo "the firmware licence file does not match its pinned checksum: nothing installed" >&2; exit 1; }
bunzip2 -c "$T/edk2.fd.bz2" > "$T/edk2-aarch64-code.fd"
[ "$(stat -f %z "$T/edk2-aarch64-code.fd")" = 67108864 ] || { echo "the firmware is not a 64 MiB flash image: nothing installed" >&2; exit 1; }
mv "$T/edk2-aarch64-code.fd" "$DIR/edk2-aarch64-code.fd"
mv "$T/edk2-licenses.txt" "$DIR/edk2-licenses.txt"
