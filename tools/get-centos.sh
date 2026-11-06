#!/bin/sh
# Download the CentOS Stream (GNOME) guest, built by tools/build-rpm-image.sh and published on
# github.com/adminmylinux/mylinux-releases, into out/centos (or $MYLINUX_OUT/centos), for run-omarchy.sh with DESKTOP=centos.
# The pinned release and its SHA256SUMS' own SHA-256; the work is tools/get-rpm-desktop.sh's.
# Usage: tools/get-centos.sh [--remove | --check]
KIND=centos
TITLE="CentOS Stream"
TAG=centos-2026.11.06
SUMS_SHA256=a1a4c945867797e24a5d0b3a79c42ad40db0271aa118cee55961ae241ab25077
. "$(dirname "$0")/get-rpm-desktop.sh"
