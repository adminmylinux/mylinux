#!/bin/sh
# Put the Omarchy session tool (omarchy/session) into an Omarchy root disk before its first boot, so the machine has it
# without anyone running install-session.sh inside: the script in /usr/local/bin, the units in /etc/systemd/user,
# enabled for every graphical session of every account. Written with debugfs (e2fsprogs, in the QEMU runtime) straight
# into the ext4 image: nothing is mounted and nothing from the disk runs. run-omarchy.sh does this on a machine's first
# start; on a stopped machine's disk it can be run again to update the tool.
# Usage: tools/omarchy-bake-session.sh <disk.ext4> [<session folder>]     MYLINUX_DEBUGFS=path names the debugfs to use
# Exit: 0 baked, 3 no debugfs available (the caller carries on; the tool can still be installed inside Omarchy).
set -eu
cd "$(dirname "$0")/.."
DISK=${1:?disk image}; SRC=${2:-omarchy/session}
OUT="${MYLINUX_OUT:-out}"
die() { echo "omarchy-bake-session.sh: $*" >&2; exit "${2:-1}"; }
if [ -n "${MYLINUX_DEBUGFS:-}" ]; then DEBUGFS=$MYLINUX_DEBUGFS
else
  DEBUGFS=""
  for c in "$OUT/qemu-runtime/bin/debugfs" /opt/homebrew/opt/e2fsprogs/sbin/debugfs; do [ -x "$c" ] && { DEBUGFS=$c; break; }; done
fi
[ -n "$DEBUGFS" ] && [ -x "$DEBUGFS" ] || die "no debugfs (the runtime's bin/debugfs, or Homebrew's e2fsprogs): nothing baked" 3
[ -f "$DISK" ] && [ -w "$DISK" ] || die "$DISK is not a writable file" 2
UNITS="omarchy-session-save.service omarchy-session-save.timer omarchy-session-restore.service omarchy-session-agent.service"
WANTED="omarchy-session-save.timer omarchy-session-restore.service omarchy-session-agent.service"
for f in omarchy-session $UNITS; do [ -f "$SRC/$f" ] || die "$SRC/$f is missing" 2; done
T=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-bake.XXXXXX"); trap 'rm -rf "$T"' EXIT
# the copies debugfs writes: their local mode becomes the inode's mode; the units run the system-wide script
install -m 0755 "$SRC/omarchy-session" "$T/omarchy-session"
for u in $UNITS; do sed 's|%h/.local/bin/omarchy-session|/usr/local/bin/omarchy-session|g' "$SRC/$u" > "$T/$u"; chmod 0644 "$T/$u"; done
BIN=/usr/local/bin; UDIR=/etc/systemd/user; WANTS=$UDIR/graphical-session.target.wants
{
  for d in /usr/local $BIN /etc/systemd $UDIR $WANTS; do echo "mkdir $d"; done      # "already exists" is fine
  echo "rm $BIN/omarchy-session"; echo "write $T/omarchy-session $BIN/omarchy-session"
  for u in $UNITS; do echo "rm $UDIR/$u"; echo "write $T/$u $UDIR/$u"; done
  for u in $WANTED; do echo "rm $WANTS/$u"; echo "symlink $WANTS/$u $UDIR/$u"; done
} > "$T/commands"
"$DEBUGFS" -w -f "$T/commands" "$DISK" > "$T/log" 2>&1 || { cat "$T/log" >&2; die "debugfs failed on $DISK"; }
# debugfs carries on after a failed command, so the result is checked, not its exit status
check() { "$DEBUGFS" -R "stat $1" "$DISK" 2>/dev/null | grep -q "$2" || { cat "$T/log" >&2; die "$1 was not written as expected ($2)"; }; }
check "$BIN/omarchy-session" "Type: regular"; check "$BIN/omarchy-session" "Mode:  0755"
check "$BIN/omarchy-session" "Size: $(wc -c < "$T/omarchy-session" | tr -d ' ')"
for u in $UNITS; do check "$UDIR/$u" "Type: regular"; done
for u in $WANTED; do check "$WANTS/$u" "Type: symlink"; done
echo "baked the Omarchy session tool into $DISK ($BIN/omarchy-session, units in $UDIR, enabled for graphical sessions)"
