# Apps-disk identification, sourced by S45apps and apps-setup (sh, busybox tools only).
# The disk is found by the virtio serial run.sh gives it ("mylinux-apps", /sys/block/vdX/serial). Without
# a serial (another launcher) the only fallback is a single virtio disk that already carries the ext4
# label "apps". Anything else is reported, never chosen and never formatted.
SYSBLOCK="${SYSBLOCK:-/sys/block}"; DEVDIR="${DEVDIR:-/dev}"

# disk_state DEV -> apps | blank | foreign | unreadable
# ext4 superblock at 1 KiB: magic 0xEF53 at +56, volume name (16 bytes) at +120. "blank" means the whole
# first MiB read back as zeros; a short or failed read is "unreadable", not blank.
disk_state() {
  n=$(dd if="$1" bs=1024 count=1024 2>/dev/null | wc -c | tr -d ' ')
  [ "$n" = 1048576 ] || { echo unreadable; return 0; }
  magic=$(dd if="$1" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$magic" = 53ef ]; then
    label=$(dd if="$1" bs=1 skip=1144 count=16 2>/dev/null | tr -d '\0')
    [ "$label" = apps ] && echo apps || echo foreign
    return 0
  fi
  nz=$(dd if="$1" bs=1024 count=1024 2>/dev/null | tr -d '\0' | wc -c | tr -d ' ')
  [ "$nz" = 0 ] && echo blank || echo foreign
}

disk_serial() { cat "$1/serial" 2>/dev/null | tr -d ' \n'; }

# find_apps_disk -> prints the device; exit 0 found, 1 none, 2 ambiguous (all candidates printed)
find_apps_disk() {
  found=""
  for b in "$SYSBLOCK"/vd*; do
    [ -e "$b" ] || continue
    [ "$(disk_serial "$b")" = mylinux-apps ] && found="$found $DEVDIR/${b##*/}"
  done
  # shellcheck disable=SC2086
  set -- $found
  [ $# -eq 1 ] && { echo "$1"; return 0; }
  [ $# -gt 1 ] && { echo "$@"; return 2; }
  for b in "$SYSBLOCK"/vd*; do          # no serial anywhere: a disk that is already ours by label
    [ -e "$b" ] || continue
    [ -n "$(disk_serial "$b")" ] && continue
    [ "$(disk_state "$DEVDIR/${b##*/}")" = apps ] && found="$found $DEVDIR/${b##*/}"
  done
  # shellcheck disable=SC2086
  set -- $found
  [ $# -eq 1 ] && { echo "$1"; return 0; }
  [ $# -gt 1 ] && { echo "$@"; return 2; }
  return 1
}
