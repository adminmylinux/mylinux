#!/bin/sh
# Put a new Omarchy machine's first-start answers into its root disk before its first boot, so Omarchy sets itself up
# without its questions (mylinux create omarchy --unattended): the answers as /var/lib/mylinux/answers (root's alone),
# the gum that gives them and the setup that uses it (omarchy/answers), and a drop-in that has Omarchy's setup service
# run that setup. All of it removes itself inside Omarchy when the setup ends. Written with debugfs (e2fsprogs, in the
# QEMU runtime) straight into the ext4 image, as tools/omarchy-bake-session.sh does: nothing is mounted and nothing
# from the disk runs. The answers are read where they lie (no second copy on the Mac); the caller removes them.
# Usage: tools/omarchy-bake-answers.sh <disk.ext4> <answers file> [<answers folder>]   MYLINUX_DEBUGFS=path names the debugfs to use
#        the answers file: lines of key=value (keyboard, username, password, fullname, email, hostname, timezone, confirm)
# Exit: 0 baked; 3 no debugfs available, 4 this disk's first-start setup is not the one the answers are for (either
#       way nothing is written: the caller carries on and Omarchy asks its questions).
set -eu
CALLER="$PWD"
cd "$(dirname "$0")/.."
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$CALLER" "$1" ;; esac; }
DISK=$(abs "${1:?disk image}"); ANSWERS=$(abs "${2:?answers file}"); SRC=${3:-omarchy/answers}
OUT="${MYLINUX_OUT:-out}"
die() { echo "omarchy-bake-answers.sh: $1" >&2; exit "${2:-1}"; }
if [ -n "${MYLINUX_DEBUGFS:-}" ]; then DEBUGFS=$MYLINUX_DEBUGFS
else
  DEBUGFS=""
  for c in "$OUT/qemu-runtime/bin/debugfs" /opt/homebrew/opt/e2fsprogs/sbin/debugfs; do [ -x "$c" ] && { DEBUGFS=$c; break; }; done
fi
[ -n "$DEBUGFS" ] && [ -x "$DEBUGFS" ] || die "no debugfs (the runtime's bin/debugfs, or Homebrew's e2fsprogs): nothing baked" 3
case "$DEBUGFS" in /*) ;; *) DEBUGFS="$PWD/$DEBUGFS" ;; esac                        # (it is run from the answers' folder below)
[ -f "$DISK" ] && [ -w "$DISK" ] || die "$DISK is not a writable file" 2
[ -f "$ANSWERS" ] && [ -s "$ANSWERS" ] || die "$ANSWERS is not a file with answers in it" 2
for f in gum provision 20-mylinux-answers.conf; do [ -f "$SRC/$f" ] || die "$SRC/$f is missing" 2; done
grep -q '^username=.' "$ANSWERS" && grep -q '^password=.' "$ANSWERS" || die "the answers name no user or no password" 2
# debugfs reads the answers by their name in their own folder (a path with a space in it is two words to it)
FOLDER=$(dirname "$ANSWERS"); FILE=$(basename "$ANSWERS")
case "$FILE" in *[!A-Za-z0-9._-]*) die "the answers file's name is letters, digits, dots and hyphens: $FILE" 2 ;; esac
T=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-answers.XXXXXX"); trap 'rm -rf "$T"' EXIT
# the setup these answers are for: Omarchy's deferred first-start setup, waiting, with the one-attempt entry and gum
seen() { "$DEBUGFS" -R "stat $1" "$DISK" 2>/dev/null | grep -q "Type: regular"; }
seen /usr/bin/gum && seen /var/lib/omarchy/provisioning/pending && seen /etc/systemd/system/omarchy-provision-owner.service \
  && "$DEBUGFS" -R "cat /usr/bin/omarchy-provision-owner" "$DISK" 2>/dev/null | grep -q -- '== "--attempt"' \
  || die "$DISK has no first-start setup of the kind the answers are for: nothing baked" 4
# the copies debugfs writes: their local mode becomes the inode's mode
install -m 0755 "$SRC/gum" "$T/gum"; install -m 0755 "$SRC/provision" "$T/provision"
install -m 0644 "$SRC/20-mylinux-answers.conf" "$T/20-mylinux-answers.conf"
chmod 600 "$ANSWERS"
DIR=/var/lib/mylinux; DROPIN=/etc/systemd/system/omarchy-provision-owner.service.d
{
  for d in $DIR $DIR/bin $DROPIN; do echo "mkdir $d"; done                          # "already exists" is fine
  echo "sif $DIR mode 040700"
  echo "rm $DIR/bin/gum"; echo "write $T/gum $DIR/bin/gum"
  echo "rm $DIR/provision"; echo "write $T/provision $DIR/provision"
  echo "rm $DROPIN/20-mylinux-answers.conf"; echo "write $T/20-mylinux-answers.conf $DROPIN/20-mylinux-answers.conf"
  echo "rm $DIR/answers"; echo "write $FILE $DIR/answers"
} > "$T/commands"
(cd "$FOLDER" && "$DEBUGFS" -w -f "$T/commands" "$DISK") > "$T/log" 2>&1 || { cat "$T/log" >&2; die "debugfs failed on $DISK"; }
# debugfs carries on after a failed command, so the result is checked, not its exit status
check() { "$DEBUGFS" -R "stat $1" "$DISK" 2>/dev/null | grep -q "$2" || { grep -v "^debugfs: write $FILE" "$T/log" >&2; die "$1 was not written as expected ($2)"; }; }
check $DIR "Mode:  0700"
check $DIR/answers "Type: regular"; check $DIR/answers "Mode:  0600"; check $DIR/answers "User:     0"
check $DIR/answers "Size: $(wc -c < "$ANSWERS" | tr -d ' ')"
check $DIR/bin/gum "Mode:  0755"; check $DIR/provision "Mode:  0755"; check $DIR/provision "Size: $(wc -c < "$T/provision" | tr -d ' ')"
check $DROPIN/20-mylinux-answers.conf "Type: regular"
echo "baked the first-start answers into $DISK (Omarchy sets itself up for $(sed -n 's/^username=//p' "$ANSWERS" | head -n 1) without its questions)"
