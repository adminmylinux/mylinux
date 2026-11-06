#!/bin/sh
# Download the Rocky Linux (GNOME) guest, built by tools/build-rpm-image.sh and published on
# github.com/adminmylinux/mylinux-releases, into out/rocky (or $MYLINUX_OUT/rocky), for run-omarchy.sh with DESKTOP=rocky.
# The pinned release and its SHA256SUMS' own SHA-256; the work is tools/get-rpm-desktop.sh's.
# Usage: tools/get-rocky.sh [--remove | --check]
KIND=rocky
TITLE="Rocky Linux"
TAG=rocky-2026.11.06-2
SUMS_SHA256=4b7fb935ee6196d3a513c937d24929e25ef456343b1691e9e1f31f4feb1434cf
. "$(dirname "$0")/get-rpm-desktop.sh"
