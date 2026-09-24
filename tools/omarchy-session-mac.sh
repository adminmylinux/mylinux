#!/bin/sh
# The Mac side of the Session menu in an Omarchy window: drops a command into the machine's share folder, where the
# omarchy-session agent inside Omarchy picks it up (see omarchy/session). run-omarchy.sh hands QEMU this script in
# MYLINUX_SESSION_CMD and the share folder in MYLINUX_SESSION_SHARE; the window runs it without a shell. Usage: omarchy-session-mac.sh <share dir> save|restore|interval <min|off>
set -eu
SHARE=${1:?share dir}; shift
[ $# -ge 1 ] || { echo "usage: omarchy-session-mac.sh <share dir> save|restore|interval <minutes|off>" >&2; exit 64; }
case "$1" in save|restore|interval) ;; *) echo "unknown session command: $1" >&2; exit 64 ;; esac
D="$SHARE/mylinux-tools/control"; mkdir -p "$D"
printf '%s\n' "$*" > "$D/.cmd.$$" && mv "$D/.cmd.$$" "$D/$(date +%s)-$$.cmd"
