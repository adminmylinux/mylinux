#!/bin/sh
# Tiny Alpine's boot, in place of OpenRC: the virtual filesystems, the name, the network, and what the launcher
# expects of a server machine: the account "alpine" (doas without a password) with this machine's SSH key and
# console password, sshd, the Mac share at /mnt/mac. The settings come from /etc/mylinux/seed (run-server.sh writes
# them into the initrd at every start). OpenSSH and doas are not in the mini root filesystem: apk adds them at the
# first start, which therefore needs the network once. /etc/local.d/*.start run last, as Alpine's "local" service
# would run them (alpine_install.sh puts Tailscale's daemon there).
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
S=/etc/mylinux/seed
U=alpine
say() { echo "tiny: $*"; }

mount -t proc proc /proc 2>/dev/null; mount -t sysfs sys /sys 2>/dev/null
mkdir -p /dev/pts /dev/shm
mount -t devpts -o gid=5,mode=620 devpts /dev/pts
mount -t tmpfs -o nosuid,nodev shm /dev/shm
mount -t tmpfs -o nosuid,nodev,mode=755 run /run
[ -e /dev/fd ] || ln -s /proc/self/fd /dev/fd
find /tmp -mindepth 1 -delete 2>/dev/null; chmod 1777 /tmp
dmesg -n 1                               # kernel messages stay out of the console's login prompt

NAME=$(cat "$S/hostname" 2>/dev/null); [ -n "$NAME" ] || NAME=tiny
hostname "$NAME"; echo "$NAME" > /etc/hostname
grep -q "[[:space:]]$NAME\$" /etc/hosts 2>/dev/null || echo "127.0.1.1 $NAME" >> /etc/hosts
syslogd -C512                            # a small log in memory: logread shows it

ip link set lo up
ip link set eth0 up 2>/dev/null && udhcpc -i eth0 -n -t 10 -T 1 -S -p /run/udhcpc.eth0.pid >/dev/null 2>&1 \
  || say "no network (eth0 got no address)"

# ---- the account: uid 1000, which is how the Mac's files in the share appear ----
if ! id "$U" >/dev/null 2>&1; then
  addgroup -g 1000 "$U" && adduser -D -u 1000 -G "$U" -s /bin/ash -g Alpine "$U" && addgroup "$U" wheel
fi
[ ! -s "$S/console-password" ] || echo "$U:$(head -1 "$S/console-password")" | chpasswd >/dev/null 2>&1
if [ -s "$S/authorized_keys" ]; then
  install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"
  touch "/home/$U/.ssh/authorized_keys"
  while read -r key; do
    [ -z "$key" ] || grep -qxF "$key" "/home/$U/.ssh/authorized_keys" || echo "$key" >> "/home/$U/.ssh/authorized_keys"
  done < "$S/authorized_keys"
  chown "$U:$U" "/home/$U/.ssh/authorized_keys"; chmod 600 "/home/$U/.ssh/authorized_keys"
fi

# ---- OpenSSH and doas, once ----
if [ ! -x /usr/sbin/sshd ] || [ ! -x /usr/bin/doas ]; then
  say "first start: adding OpenSSH and doas ..."
  timeout 180 apk add -q openssh-server openssh-sftp-server doas \
    || say "that failed (no network?). It is tried again at the next start; the console below works meanwhile."
fi
if [ -x /usr/bin/doas ]; then
  mkdir -p /etc/doas.d; echo "permit nopass $U" > /etc/doas.d/20-mylinux.conf; chmod 600 /etc/doas.d/20-mylinux.conf
fi
if [ -x /usr/sbin/sshd ]; then
  # keys only; local forwarding for the launcher's browser pane (ssh -D, ssh -L), which Alpine's sshd forbids
  mkdir -p /etc/ssh/sshd_config.d
  printf 'PasswordAuthentication no\nAllowTcpForwarding local\n' > /etc/ssh/sshd_config.d/60-mylinux.conf
  ssh-keygen -A >/dev/null 2>&1
  /usr/sbin/sshd || say "sshd did not start"
fi

# ---- the Mac share (the 9p device with the tag mac), then whatever /etc/fstab names (the cloud folders) ----
if cat /sys/bus/virtio/drivers/9pnet_virtio/virtio*/mount_tag 2>/dev/null | tr '\000' '\n' | grep -qx mac; then
  mkdir -p /mnt/mac
  if mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 mac /mnt/mac; then
    LINK=$(cat "$S/share-name" 2>/dev/null)
    case "$LINK" in ''|*/*|.|..) ;; *) [ -e "/home/$U/$LINK" ] && [ ! -L "/home/$U/$LINK" ] || { ln -sfn /mnt/mac "/home/$U/$LINK"; chown -h "$U:$U" "/home/$U/$LINK"; } ;; esac
  fi
fi
mount -a 2>/dev/null

# ---- Stop: the launcher presses the power key of the machine's keyboard, and BusyBox's acpid runs this ----
mkdir -p /etc/acpi/PWRF
printf '#!/bin/sh\npoweroff\n' > /etc/acpi/PWRF/00000080; chmod 755 /etc/acpi/PWRF/00000080
acpid 2>/dev/null

for f in /etc/local.d/*.start; do [ -x "$f" ] && "$f"; done
exit 0
