#!/bin/sh
# Download the Fedora (GNOME) guest, built by tools/build-rpm-image.sh and published on
# github.com/adminmylinux/mylinux-releases, into out/fedora (or $MYLINUX_OUT/fedora), for run-omarchy.sh with DESKTOP=fedora.
# The pinned release and its SHA256SUMS' own SHA-256; the work is tools/get-rpm-desktop.sh's.
# Usage: tools/get-fedora.sh [--remove | --check]
KIND=fedora
TITLE="Fedora"
TAG=fedora-2026.11.06-2
SUMS_SHA256=27dc3eff4eadb6cc103c8bc7b73703f4edfb75725c33afe9359d79db3eebbffa
. "$(dirname "$0")/get-rpm-desktop.sh"
