#!/bin/sh
# Download the Rocky Linux (GNOME) guest, built by tools/build-rpm-image.sh and published on
# github.com/adminmylinux/mylinux-releases, into out/rocky (or $MYLINUX_OUT/rocky), for run-omarchy.sh with DESKTOP=rocky.
# The pinned release and its SHA256SUMS' own SHA-256; the work is tools/get-rpm-desktop.sh's.
# Usage: tools/get-rocky.sh [--remove | --check]
KIND=rocky
TITLE="Rocky Linux"
TAG=rocky-2026.11.06
SUMS_SHA256=3287f7d6b9fd26906c001f5b76c764ebcb4341313d25a03eab77df86b6eef8c5
. "$(dirname "$0")/get-rpm-desktop.sh"
