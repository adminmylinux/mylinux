#!/bin/sh
# Keep the session tool baked into an Omarchy root disk (tools/omarchy-bake-session.sh) up to date: run-omarchy.sh
# calls this at each start of a machine made earlier, before QEMU has the disk, so an agent from an older launcher
# learns what the Mac window asks of it now (the "apps" command of Apps…). Only a disk that was shut down cleanly is
# written: debugfs never touches one whose journal still needs replaying (a force-quit), which is left for a later start.
# Usage: tools/omarchy-update-session.sh <disk.ext4> [<session folder>]
# Exit: 0 up to date (or updated), 4 not clean (left alone), 3 no debugfs, 1 the update failed.
set -eu
cd "$(dirname "$0")/.."
DISK=${1:?disk image}; SRC=${2:-omarchy/session}
OUT="${MYLINUX_OUT:-out}"
DBG=${MYLINUX_DEBUGFS:-$OUT/qemu-runtime/bin/debugfs}
[ -x "$DBG" ] || { echo "omarchy-update-session.sh: no debugfs" >&2; exit 3; }
if "$DBG" -R "cat /usr/local/bin/omarchy-session" "$DISK" 2>/dev/null | cmp -s - "$SRC/omarchy-session"; then exit 0; fi
STATS=$("$DBG" -R stats "$DISK" 2>/dev/null || true)
if ! printf '%s\n' "$STATS" | grep -Eq '^Filesystem state: +clean$' || printf '%s\n' "$STATS" | grep -q needs_recovery; then
  echo "omarchy-update-session.sh: $DISK was not shut down cleanly; its session tool is updated at a later start" >&2
  exit 4
fi
MYLINUX_DEBUGFS=$DBG tools/omarchy-bake-session.sh "$DISK" "$SRC" >/dev/null || exit 1
echo "updated the session tool in $DISK"
