#!/bin/sh
# Download the Fedora (GNOME) guest, built by tools/build-rpm-image.sh and published on
# github.com/adminmylinux/mylinux-releases, into out/fedora (or $MYLINUX_OUT/fedora), for run-omarchy.sh with DESKTOP=fedora.
# The pinned release and its SHA256SUMS' own SHA-256; the work is tools/get-rpm-desktop.sh's.
# Usage: tools/get-fedora.sh [--remove | --check]
KIND=fedora
TITLE="Fedora"
TAG=fedora-2026.11.06
SUMS_SHA256=f0fe669fb16b02532e03695f3fdf1a75e7383b772e1150325b936a1d64232d29
. "$(dirname "$0")/get-rpm-desktop.sh"
