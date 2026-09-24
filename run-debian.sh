#!/bin/sh
# Boot a Debian server machine on the Mac: the Debian cloud image (tools/get-debian.sh) on the accelerated QEMU
# runtime or Homebrew's QEMU, with no display at all. The machine is a terminal server: its serial console is on
# SERIAL, SSH is forwarded to a port on this Mac, and the launcher opens a terminal to it. Every machine has its own
# disk, made on the first start from the downloaded image (sparse, grown to DISK_SIZE_GB; cloud-init grows the root
# filesystem into it on boot) and set up by cloud-init from a seed made here: the "debian" account with an SSH key
# generated for this machine (<machine>/ssh_key), a random console password (<machine>/console-password), sudo,
# the Mac share mounted at /mnt/mac and linked from the home folder.
# Environment: DISK=path of the root disk (default $MYLINUX_OUT/debian-machine/debian.raw), DISK_SIZE_GB=32, NAME=machine
#              name (also the host name), MEM=2G, CPUS, SHARE_DIR=folder shown inside as ~/<its name> (optional),
#              SERIAL=chardev for the console (default: file <machine>/console.log; unix:<path>,server,nowait for the launcher),
#              QMP=unix socket path for control (a clean stop is {"execute":"system_powerdown"} there),
#              SSH_PORT=port on 127.0.0.1 forwarded to the guest's sshd (default 2223), FORWARD=host:guest[,...] more ports,
#              DRYRUN=1 prints the QEMU command, MYLINUX_OUT=dir with debian/ and qemu-runtime/, MYLINUX_QEMU=brew|runtime.
set -eu
cd "$(dirname "$0")"
REPO=$(pwd)
die() { echo "run-debian.sh: $*" >&2; exit 1; }
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
OUT=$(abs "${MYLINUX_OUT:-out}")
G="$OUT/debian"
FLAVOUR=$(sh tools/qemu-flavour.sh "$OUT")
if [ "$FLAVOUR" = runtime ]; then
  QEMU="$OUT/qemu-runtime/bin/qemu-system-aarch64"; MACHINE_TYPE="virt,gic-version=3"; ROM=",romfile="; OWNER=",guest_owner_uid=1000,guest_owner_gid=1000"
else
  QEMU=$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v qemu-system-aarch64) || die "qemu-system-aarch64 not found (tools/get-qemu-runtime.sh, or brew install qemu)"
  MACHINE_TYPE="virt"; ROM=""; OWNER=""
fi
NAME="${NAME:-Debian}"
HOSTNAME=$(printf '%s' "$NAME" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'); [ -n "$HOSTNAME" ] || HOSTNAME=debian
MEM="${MEM:-2G}"
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
CPUS="${CPUS:-$(( NCPU > 8 ? 4 : 2 ))}"
case "$CPUS" in ''|*[!0-9]*) die "CPUS must be a number" ;; esac
[ "$CPUS" -ge 1 ] && [ "$CPUS" -le "$NCPU" ] || die "CPUS out of range: $CPUS (this Mac has $NCPU)"
DISK=$(abs "${DISK:-$OUT/debian-machine/debian.raw}")
MACHINE=$(dirname "$DISK")
DISK_SIZE_GB="${DISK_SIZE_GB:-32}"
case "$DISK_SIZE_GB" in ''|*[!0-9]*) die "DISK_SIZE_GB must be a whole number of GB" ;; esac
[ "$DISK_SIZE_GB" -ge 8 ] && [ "$DISK_SIZE_GB" -le 2000 ] || die "DISK_SIZE_GB out of range: $DISK_SIZE_GB (8-2000)"
SSH_PORT="${SSH_PORT:-2223}"
case "$SSH_PORT" in ''|*[!0-9]*) die "SSH_PORT must be a number" ;; esac
[ "$SSH_PORT" -ge 1024 ] && [ "$SSH_PORT" -le 65535 ] || die "SSH_PORT out of range: $SSH_PORT (1024-65535)"
NETDEV="user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
for fw in $(printf '%s' "${FORWARD:-}" | tr ',' ' '); do
  case "$fw" in [0-9]*:[0-9]*) NETDEV="$NETDEV,hostfwd=tcp:127.0.0.1:${fw%%:*}-:${fw##*:}" ;; *) die "FORWARD entries look like hostport:guestport (got '$fw')" ;; esac
done
case "$DISK$MACHINE$OUT" in *,*) die "paths must not contain a comma (QEMU's option syntax)" ;; esac

# ---- the shared folder: /mnt/mac inside, and ~/<its name>; the runtime's 9p shows the Mac's files as the guest's user
SHARE_DIR="${SHARE_DIR:-}"; SHARE_NAME=""
if [ -n "$SHARE_DIR" ]; then
  SHARE_DIR=$(abs "$SHARE_DIR"); SHARE_NAME=$(basename "$SHARE_DIR")
  case "$SHARE_DIR" in *,*) die "the share folder's path must not contain a comma" ;; esac
  # never a system folder, the whole home folder or the user's Library (the launcher's machine folders excepted)
  case "$SHARE_DIR" in
    "$HOME/Library/Application Support/myLinux/machines"/?*) ;;
    /|/Users|/private|/tmp|/private/tmp|/System|/Library|/Applications|/Volumes|"$HOME"|"$HOME/Library"|"$HOME/Library"/*) die "refusing to share $SHARE_DIR (a system folder, the home folder or the Library)" ;;
  esac
  [ "${DRYRUN:-0}" = 1 ] || mkdir -p "$SHARE_DIR"
fi

# ---- first start: the disk from the image, the SSH key, the console password, the cloud-init seed --------------
SEED="$MACHINE/seed.iso"
if [ "${DRYRUN:-0}" != 1 ] && { [ ! -f "$DISK" ] || [ ! -s "$SEED" ]; }; then
  [ -s "$G/debian.raw" ] && [ -s "$G/edk2-aarch64-code.fd" ] || die "the Debian image is not downloaded: run tools/get-debian.sh"
  mkdir -p "$MACHINE"
  if [ ! -f "$DISK" ]; then
    echo "creating $DISK ($DISK_SIZE_GB GB, sparse) from Debian $(cat "$G/DEBIAN-REVISION" 2>/dev/null) ..."
    python3 tools/sparse-copy.py "$G/debian.raw" "$DISK" "$DISK_SIZE_GB" || { rm -f "$DISK" "$DISK.new"; die "could not create the disk"; }
    cp "$G/DEBIAN-REVISION" "$MACHINE/DEBIAN-REVISION" 2>/dev/null || true
  fi
  [ -s "$MACHINE/ssh_key" ] || ssh-keygen -q -t ed25519 -N '' -C "myLinux $HOSTNAME" -f "$MACHINE/ssh_key" || die "could not make the SSH key (ssh-keygen)"
  if [ ! -s "$MACHINE/console-password" ]; then
    (umask 077; LC_ALL=C tr -dc 'a-hj-np-z2-9' < /dev/urandom | head -c 14 > "$MACHINE/console-password"; echo >> "$MACHINE/console-password")
  fi
  PASSWORD=$(head -1 "$MACHINE/console-password")
  PUBKEY=$(cat "$MACHINE/ssh_key.pub")
  SEEDDIR="$MACHINE/.seed"; rm -rf "$SEEDDIR"; mkdir -p "$SEEDDIR"
  {
    echo "#cloud-config"
    echo "hostname: $HOSTNAME"
    echo "manage_etc_hosts: true"
    echo "users:"
    echo "  - name: debian"
    echo "    gecos: Debian"
    echo "    shell: /bin/bash"
    echo "    sudo: \"ALL=(ALL) NOPASSWD:ALL\""
    echo "    lock_passwd: false"
    echo "    ssh_authorized_keys:"
    echo "      - \"$PUBKEY\""
    echo "chpasswd:"
    echo "  expire: false"
    echo "  users:"
    echo "    - {name: debian, password: \"$PASSWORD\", type: text}"
    echo "ssh_pwauth: false"
    echo "package_update: false"
    if [ -n "$SHARE_DIR" ]; then
      echo "mounts:"
      echo "  - [mac, /mnt/mac, 9p, \"trans=virtio,version=9p2000.L,msize=512000,nofail,_netdev\", \"0\", \"0\"]"
      echo "runcmd:"
      echo "  - [sh, -c, \"ln -sfn /mnt/mac '/home/debian/$SHARE_NAME' && chown -h debian:debian '/home/debian/$SHARE_NAME'\"]"
    fi
  } > "$SEEDDIR/user-data"
  printf 'instance-id: mylinux-%s\nlocal-hostname: %s\n' "$HOSTNAME" "$HOSTNAME" > "$SEEDDIR/meta-data"
  rm -f "$SEED"
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$SEED" "$SEEDDIR" || die "could not make the cloud-init seed (hdiutil)"
  rm -rf "$SEEDDIR"
fi
SERIAL="${SERIAL:-file:$MACHINE/console.log}"
case "$SERIAL" in
  file:*) CONSOLE="file,id=con,path=${SERIAL#file:}" ;;
  unix:*) CONSOLE="socket,id=con,path=${SERIAL#unix:}"; CONSOLE=$(printf '%s' "$CONSOLE" | sed 's/,server,nowait$/,server=on,wait=off/') ;;
  *) die "SERIAL must be file:<path> or unix:<path>,server,nowait" ;;
esac

set -- \
  -name "$NAME" -M "$MACHINE_TYPE" -accel hvf -cpu host -smp "$CPUS" -m "$MEM" \
  -bios "$G/edk2-aarch64-code.fd" \
  -drive "if=none,id=root,file=$DISK,format=raw,media=disk,cache=writeback" -device "virtio-blk-pci,drive=root,serial=debian-root$ROM" \
  -drive "if=none,id=seed,file=$SEED,format=raw,media=disk,readonly=on" -device "virtio-blk-pci,drive=seed,serial=cidata$ROM" \
  -netdev "$NETDEV" -device "virtio-net-pci,netdev=n0$ROM" \
  -object rng-random,id=rng0,filename=/dev/urandom -device "virtio-rng-pci,rng=rng0$ROM" \
  -device "virtio-balloon-pci$ROM" \
  -display none -chardev "$CONSOLE" -serial chardev:con \
  "$@"
if [ -n "$SHARE_DIR" ]; then
  set -- "$@" -fsdev "local,id=share,path=$SHARE_DIR,security_model=none,multidevs=remap$OWNER" \
    -device "virtio-9p-pci,fsdev=share,mount_tag=mac$ROM"
fi
[ -z "${QMP:-}" ] || set -- "$@" -qmp "unix:$QMP,server=on,wait=off"
if [ "${DRYRUN:-0}" = 1 ]; then
  echo "QEMU=$FLAVOUR DISK=$DISK SEED=$SEED SHARE_DIR=$SHARE_DIR NAME=$NAME HOSTNAME=$HOSTNAME CPUS=$CPUS MEM=$MEM SSH_PORT=$SSH_PORT"
  for a in "$@"; do printf '%s\n' "$a"; done
  exit 0
fi
[ -x "$QEMU" ] || die "$QEMU is missing"
[ -s "$G/edk2-aarch64-code.fd" ] || die "the UEFI firmware is missing: run tools/get-debian.sh"
printf 'ssh -i %s -p %s -o UserKnownHostsFile=%s -o StrictHostKeyChecking=accept-new debian@127.0.0.1\n' "$MACHINE/ssh_key" "$SSH_PORT" "$MACHINE/known_hosts" > "$MACHINE/ssh-command"
exec "$QEMU" "$@"
