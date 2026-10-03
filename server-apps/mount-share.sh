#!/bin/sh
# myLinux: mount an SMB share (this Mac's, a NAS's, a PC's) at ~/<name>, now and at every start.
# The launcher's Mount a Share… (the CMD menu in a server's window, the ⌘ menu in Omarchy's) writes what was asked
# into the Mac share and runs this in the machine's terminal; the share's password is asked here, so it never
# passes through the Mac. Debian, Alpine and Omarchy (Arch).
#   sh mount-share.sh --from <file>              server, share, name and user, one per line (the file is removed)
#   sh mount-share.sh <server> <share> <name> [<user>]
#   sh mount-share.sh --remove <name>           unmount it and forget it
set -eu
say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif have sudo; then sudo "$@"
  elif have doas; then doas "$@"
  else die "need root for: $* (no sudo or doas)"; fi
}
CRED_DIR=/etc/mylinux/smb
MARK="# mylinux-share:"

# /etc/fstab without the two lines (the mark and the entry) of the share called $1
fstab_without() { awk -v m="$MARK $1" '$0 == m { skip = 1; next } skip { skip = 0; next } { print }' /etc/fstab; }

if [ "${1:-}" = --remove ]; then
  name="${2:-}"; case "$name" in ''|*[!A-Za-z0-9._-]*) die "usage: mount-share.sh --remove <name>" ;; esac
  mp="$HOME/$name"
  if mountpoint -q "$mp" 2>/dev/null; then as_root umount "$mp" || as_root umount -l "$mp"; fi
  fstab_without "$name" | as_root tee /etc/fstab.mylinux-new >/dev/null && as_root mv /etc/fstab.mylinux-new /etc/fstab
  as_root rm -f "$CRED_DIR/$name.cred"
  [ -d /run/systemd/system ] && as_root systemctl daemon-reload
  rmdir "$mp" 2>/dev/null || true
  say "$name is unmounted and forgotten"; exit 0
fi

if [ "${1:-}" = --from ]; then
  f="${2:-}"; [ -f "$f" ] || die "nothing asked ($f is not there)"
  { IFS= read -r server; IFS= read -r share; IFS= read -r name; IFS= read -r user || true; } <"$f"
  rm -f "$f"
else
  server="${1:-}"; share="${2:-}"; name="${3:-}"; user="${4:-}"
fi
case "$server" in ''|*[!A-Za-z0-9.:_-]*) die "the server is an address or a name, like 10.0.2.2, 192.168.0.20 or nas" ;; esac
case "$share" in ''|*/*|*\\*|*,*) die "the share is its name on the server, without / \\ or ," ;; esac
case "$name" in ''|*[!A-Za-z0-9._-]*|.*) die "the name inside is one word: letters, digits, . _ -" ;; esac
case "$user" in *[!A-Za-z0-9._@\ -]*) die "the user name has characters an SMB user cannot have" ;; esac
mp="$HOME/$name"

# cifs-utils (mount.cifs)
if ! have mount.cifs && [ ! -x /sbin/mount.cifs ] && [ ! -x /usr/sbin/mount.cifs ]; then
  say "Installing cifs-utils (SMB mounts)"
  if have apk; then as_root apk add -q cifs-utils
  elif have apt-get; then as_root apt-get update -qq && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cifs-utils
  elif have pacman; then as_root pacman -S --needed --noconfirm cifs-utils || as_root pacman -Sy --needed --noconfirm cifs-utils
  else die "install cifs-utils, then run this again"; fi
fi

# the password, here in the terminal (empty: a guest share)
if [ -r /dev/tty ] && (: </dev/tty) 2>/dev/null; then
  printf 'Password for %s on //%s/%s (empty for guest access): ' "${user:-guest}" "$server" "$share" >/dev/tty
  stty -echo </dev/tty 2>/dev/null || true
  IFS= read -r pass </dev/tty || pass=""
  stty echo </dev/tty 2>/dev/null || true
  printf '\n' >/dev/tty
else
  pass="${MYLINUX_SHARE_PASSWORD:-}"
fi

opts="uid=$(id -u),gid=$(id -g),iocharset=utf8,file_mode=0644,dir_mode=0755,nofail,_netdev"
if [ -z "$user" ] && [ -z "$pass" ]; then
  opts="guest,$opts"
else
  # the user and password in a file only root reads, named after the share inside
  printf 'username=%s\npassword=%s\n' "${user:-guest}" "$pass" | as_root sh -c "umask 077; mkdir -p $CRED_DIR; cat > $CRED_DIR/$name.cred"
  opts="credentials=$CRED_DIR/$name.cred,$opts"
fi
# systemd: mounted when first opened, so a start does not wait for a NAS that is off
[ -d /run/systemd/system ] && opts="$opts,x-systemd.automount,x-systemd.mount-timeout=20"

# fstab writes a space as \040
src="//$server/$(printf '%s' "$share" | sed 's/\\/\\134/g; s/ /\\040/g; s/	/\\011/g')"
mkdir -p "$mp"
if mountpoint -q "$mp" 2>/dev/null; then as_root umount "$mp" || as_root umount -l "$mp"; fi
{ fstab_without "$name"; printf '%s %s\n%s %s cifs %s 0 0\n' "$MARK" "$name" "$src" "$(printf '%s' "$mp" | sed 's/ /\\040/g')" "$opts"; } \
  | as_root tee /etc/fstab.mylinux-new >/dev/null && as_root mv /etc/fstab.mylinux-new /etc/fstab
if [ -d /run/systemd/system ]; then as_root systemctl daemon-reload
elif have rc-update; then as_root rc-update add netmount default >/dev/null 2>&1 || true; fi

say "Mounting //$server/$share at ~/$name"
if err="$(as_root mount "$mp" 2>&1)"; then
  n="$(ls -A "$mp" 2>/dev/null | wc -l | tr -d ' ')"
  say "~/$name is //$server/$share ($n items), and comes back at every start"
  exit 0
fi
printf '%s\n' "$err" >&2
case "$err" in
  *"Permission denied"*|*"error(13)"*)
    say "The server refused the user or password. On a Mac: System Settings › General › Sharing › File Sharing › (i) › Options: turn on your account under Windows File Sharing." ;;
  *"Host is down"*|*"No route to host"*|*"timed out"*|*"error(112)"*|*"error(113)"*|*"error(110)"*)
    say "$server cannot be reached from this machine. On a Mac with macOS 15 or later, allow this machine to find devices on your local network (System Settings › Privacy & Security › Local Network). A Tailscale address works when the Mac runs the Tailscale app (not Homebrew's userspace tailscaled)." ;;
  *"No such file"*|*"error(2)"*)
    say "The server has no share called \"$share\"." ;;
esac
say "The entry stays in /etc/fstab (mount ~/$name tries again; mount-share.sh --remove $name forgets it)"
exit 1
