#!/bin/sh
# Keep the GNOME desktops' agent (gnome/mylinux-desktop: the clipboard, and Claude Install…'s requests) in a Fedora,
# Rocky Linux or CentOS Stream root disk the same as this launcher's: run-omarchy.sh calls this at each start, before
# QEMU has the disk, so a disk from an older image learns what the Mac window asks of it now. Written with debugfs
# (the QEMU runtime's) straight into the ext4 image: nothing is mounted and nothing from the disk runs. Only a disk
# that was shut down cleanly is written (a force-quit one's journal still needs replaying): it is left for a later start.
# Usage: tools/gnome-update-desktop.sh <disk.ext4> [<agent file>]     MYLINUX_DEBUGFS=path names the debugfs to use
# Exit: 0 up to date (or updated), 4 not clean (left alone), 3 no debugfs, 1 the update failed.
set -eu
cd "$(dirname "$0")/.."
DISK=${1:?disk image}; SRC=${2:-gnome/mylinux-desktop}
OUT="${MYLINUX_OUT:-out}"
DBG=${MYLINUX_DEBUGFS:-$OUT/qemu-runtime/bin/debugfs}
DEST=/usr/local/bin/mylinux-desktop
[ -x "$DBG" ] || { echo "gnome-update-desktop.sh: no debugfs" >&2; exit 3; }
[ -f "$SRC" ] || { echo "gnome-update-desktop.sh: $SRC is missing" >&2; exit 1; }
same() { "$DBG" -R "cat $DEST" "$DISK" 2>/dev/null | cmp -s - "$SRC"; }
if same; then exit 0; fi
STATS=$("$DBG" -R stats "$DISK" 2>/dev/null || true)
if ! printf '%s\n' "$STATS" | grep -Eq '^Filesystem state: +clean$' || printf '%s\n' "$STATS" | grep -q needs_recovery; then
  echo "gnome-update-desktop.sh: $DISK was not shut down cleanly; its desktop agent is updated at a later start" >&2
  exit 4
fi
T=$(mktemp -d "${TMPDIR:-/tmp}/gnome-desktop.XXXXXX"); trap 'rm -rf "$T"' EXIT
install -m 0755 "$SRC" "$T/mylinux-desktop"      # debugfs gives the file this copy's mode (and root as its owner)
printf 'rm %s\nwrite %s %s\n' "$DEST" "$T/mylinux-desktop" "$DEST" > "$T/commands"
"$DBG" -w -f "$T/commands" "$DISK" > "$T/log" 2>&1 || { cat "$T/log" >&2; exit 1; }
# debugfs carries on after a failed command, so the result is checked, not its exit status
if ! same || ! "$DBG" -R "stat $DEST" "$DISK" 2>/dev/null | grep -q 'Mode:  0755'; then
  cat "$T/log" >&2; echo "gnome-update-desktop.sh: $DEST was not written as expected" >&2; exit 1
fi
echo "updated the desktop agent in $DISK"
