#!/bin/sh
# Download the CentOS Stream (GNOME) guest, built by tools/build-rpm-image.sh and published on
# github.com/adminmylinux/mylinux-releases, into out/centos (or $MYLINUX_OUT/centos), for run-omarchy.sh with DESKTOP=centos.
# The pinned release and its SHA256SUMS' own SHA-256; the work is tools/get-rpm-desktop.sh's.
# Usage: tools/get-centos.sh [--remove | --check]
KIND=centos
TITLE="CentOS Stream"
TAG=centos-2026.11.06-2
SUMS_SHA256=58f28023ff31baf722bbe87b31dbdf2dcbb8ae7edd3534fdcd19c23ea2bea13e
. "$(dirname "$0")/get-rpm-desktop.sh"
