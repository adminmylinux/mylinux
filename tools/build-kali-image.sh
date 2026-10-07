#!/bin/bash
# myLinux: builds the Kali Linux (Xfce) desktop image, for Apple silicon (arm64), from Kali's own packages: a
# debootstrap of kali-rolling. Kali publishes no ready-made virtual machine for arm64, only an installer. Run as
# root on an arm64 Linux (the OrbStack "debian" machine):
#   orb -m debian sudo bash tools/build-kali-image.sh [out-dir]
# It leaves, in out-dir (default out/kali-build, beside this repo), the files a machine starts from, laid out as
# Omarchy's and Arch's are (direct kernel boot, a raw ext4 root on /dev/vda):
#   vmlinuz-linux  initramfs-linux.img  rootfs.ext4.zst  SHA256SUMS  KALI-REVISION
# Inside: Kali's default desktop (Xfce, X11) signed in automatically as "kali" (password kali, sudo without one),
# QTerminal, Thunar, Firefox, Kali's top ten tools (kali-tools-top10, which on arm64 is nine: Burp Suite is not built
# for it; TOOLS= chooses other metapackages), the Mac share at /mnt/mac
# (~/Mac), and what makes it behave as the launcher's other desktops (kali/): the clipboard agent for X11 that
# speaks Try Omarchy's protocol, the desktop following the window's size, the scale for a Retina display.
set -euo pipefail
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(uname -m)" = aarch64 ] || die "needs an arm64 Linux (the OrbStack debian machine)"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/out/kali-build}"
WORK=/root/kali-build                          # on Linux's own disk: the Mac's folders are case-insensitive
SIZE_GB=16
MIRROR=http://http.kali.org/kali
KEYRING_URL=https://archive.kali.org/archive-keyring.gpg
# Kali Linux Archive Automatic Signing Key (2025) <devel@kali.org>, as kali.org/blog/new-kali-archive-signing-key names it
KALI_KEY=827C8569F2518CC677FECA1AED65462EC8D5E4C5
TOOLS="${TOOLS-kali-tools-top10}"
PACKAGES=(
  linux-image-arm64 initramfs-tools systemd-sysv dbus-user-session sudo locales
  kali-linux-core kali-desktop-xfce
  network-manager firefox-esr
  pipewire pipewire-pulse wireplumber pavucontrol
  xclip x11-xserver-utils python3 e2fsprogs
  fonts-noto-color-emoji
)
USER_NAME=kali

for t in debootstrap mkfs.ext4 losetup zstd curl gpg; do command -v $t >/dev/null || die "missing $t (apt-get install debootstrap e2fsprogs zstd curl gpg)"; done
[ -e /usr/share/debootstrap/scripts/kali-rolling ] || die "this debootstrap has no kali-rolling script"
mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ---- Kali's archive key: the packages are checked against it by debootstrap and apt ------------------------------------
if [ ! -s kali-archive-keyring.gpg ] || [ "${FRESH:-0}" = 1 ]; then
  say "Downloading Kali's archive keyring"
  curl -fL --retry 3 -o kali-archive-keyring.gpg.part "$KEYRING_URL"
  mv kali-archive-keyring.gpg.part kali-archive-keyring.gpg
fi
gpg --show-keys --with-colons kali-archive-keyring.gpg 2>/dev/null | grep -q "^fpr:::::::::$KALI_KEY:" \
  || die "kali-archive-keyring.gpg does not hold Kali's archive signing key ($KALI_KEY)"
say "Keyring holds Kali's archive signing key"

# ---- the disk: one ext4 file system, no partitions (root=/dev/vda) ----------------------------------------------------
MNT="$WORK/mnt"
kill_inside() {
  for p in /proc/[0-9]*; do
    [ "$(readlink "$p/root" 2>/dev/null)" = "$MNT" ] && kill "${p#/proc/}" 2>/dev/null
  done
  sleep 1
}
cleanup() {
  set +e
  kill_inside
  for m in var/cache/apt/archives dev/pts dev proc sys run tmp; do mountpoint -q "$MNT/$m" && umount -R "$MNT/$m"; done
  mountpoint -q "$MNT" && umount "$MNT"
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT
rm -f rootfs.ext4; truncate -s ${SIZE_GB}G rootfs.ext4
mkfs.ext4 -q -L kali-root -O ^orphan_file rootfs.ext4
mkdir -p "$MNT"; LOOP=$(losetup --find --show rootfs.ext4); mount "$LOOP" "$MNT"

say "Bootstrapping kali-rolling (arm64)"
# the downloaded packages are kept between builds: a failed or repeated build does not fetch them again
mkdir -p "$WORK/debcache" "$WORK/aptcache"
debootstrap --arch=arm64 --keyring="$WORK/kali-archive-keyring.gpg" --components=main,contrib,non-free,non-free-firmware \
  --include=kali-archive-keyring,ca-certificates --cache-dir="$WORK/debcache" kali-rolling "$MNT" "$MIRROR" > "$WORK/debootstrap.log" 2>&1 \
  || { tail -20 "$WORK/debootstrap.log" >&2; die "debootstrap failed (the whole log: $WORK/debootstrap.log)"; }

for m in proc sys dev dev/pts run tmp var/cache/apt/archives; do mkdir -p "$MNT/$m"; done
mount -t proc proc "$MNT/proc"; mount --rbind /sys "$MNT/sys"; mount --rbind /dev "$MNT/dev"
mount -t tmpfs tmpfs "$MNT/run"; mount -t tmpfs tmpfs "$MNT/tmp"
mount --bind "$WORK/aptcache" "$MNT/var/cache/apt/archives"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf.build"
inside() { chroot "$MNT" /usr/bin/env -i HOME=/root TERM=dumb PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive bash -euo pipefail -c "$1"; }

say "Packages (Xfce, QTerminal, Firefox${TOOLS:+, $TOOLS})"
inside "
  rm -f /etc/resolv.conf; cp /etc/resolv.conf.build /etc/resolv.conf
  echo 'deb $MIRROR kali-rolling main contrib non-free non-free-firmware' > /etc/apt/sources.list
  # nothing a package installs is started in the build machine
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 755 /usr/sbin/policy-rc.d
  # the initramfs is made for any machine, not fitted to the build machine
  mkdir -p /etc/initramfs-tools/conf.d; echo MODULES=most > /etc/initramfs-tools/conf.d/mylinux.conf
  apt-get -q update > /dev/null
  for try in 1 2 3; do
    apt-get -q -y -o Dpkg::Options::=--force-confnew install ${PACKAGES[*]} $TOOLS && break
    [ \$try = 3 ] && exit 1; echo 'apt failed; trying again'; sleep 5
  done
  # no hardware in a virtual machine needs firmware
  apt-get -q -y purge 'firmware-*' >/dev/null 2>&1 || true
  apt-get -q -y autoremove --purge >/dev/null 2>&1 || true
" > "$WORK/apt.log" 2>&1 || { tail -30 "$WORK/apt.log" >&2; die "installing the packages failed (the whole log: $WORK/apt.log)"; }

say "Configuring"
install -m 755 "$REPO/kali/mylinux-clipboard" "$MNT/usr/local/bin/mylinux-clipboard"
install -m 755 "$REPO/kali/mylinux-desktop" "$MNT/usr/local/bin/mylinux-desktop"
install -D -m 644 "$REPO/kali/mylinux-desktop.desktop" "$MNT/etc/xdg/autostart/mylinux-desktop.desktop"
install -D -m 644 "$REPO/kali/55mylinux-scale" "$MNT/etc/X11/Xsession.d/55mylinux-scale"
install -m 644 "$REPO/kali/60-mylinux-clipboard.rules" "$MNT/etc/udev/rules.d/60-mylinux-clipboard.rules"
# X draws in software: its OpenGL acceleration (glamor) on QEMU's virgl, which ANGLE draws on the Mac, is a black screen
install -D -m 644 "$REPO/kali/20-mylinux-modesetting.conf" "$MNT/etc/X11/xorg.conf.d/20-mylinux-modesetting.conf"
inside "
  echo kali > /etc/hostname
  printf '127.0.0.1 localhost\n127.0.1.1 kali\n::1 localhost ip6-localhost ip6-loopback\n' > /etc/hosts
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; locale-gen >/dev/null; echo LANG=en_US.UTF-8 > /etc/default/locale
  ln -sf /usr/share/zoneinfo/UTC /etc/localtime

  # the account: Kali's own name and password (uid 1000, as the Mac share's files are mapped), sudo without asking
  id $USER_NAME >/dev/null 2>&1 || useradd -m -u 1000 -s /usr/bin/zsh $USER_NAME
  for g in sudo audio video input netdev plugdev dialout kaboxer wireshark; do getent group \$g >/dev/null && usermod -aG \$g $USER_NAME; done
  echo '$USER_NAME:kali' | chpasswd; passwd -l root >/dev/null
  echo '$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-mylinux; chmod 440 /etc/sudoers.d/10-mylinux

  # boot: a raw ext4 on /dev/vda, grown to the machine's disk size at each start; the Mac share
  echo '/dev/vda / ext4 rw,relatime 0 1' > /etc/fstab
  echo 'mac /mnt/mac 9p trans=virtio,version=9p2000.L,msize=524288,access=client,nofail,x-systemd.automount,x-systemd.device-timeout=5 0 0' >> /etc/fstab
  mkdir -p /mnt/mac; ln -sfn /mnt/mac /home/$USER_NAME/Mac
  printf '[Unit]\nDescription=myLinux: the root file system takes the whole disk\nAfter=systemd-remount-fs.service\n\n[Service]\nType=oneshot\nExecStart=/sbin/resize2fs /dev/vda\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/mylinux-growfs.service
  printf 'virtio_pci\nvirtio_blk\nvirtio_gpu\nvirtio_net\nvirtio_console\nvirtio_input\nvirtio_balloon\nvirtio_rng\n9p\n9pnet_virtio\n' >> /etc/initramfs-tools/modules
  update-initramfs -u -k all >/dev/null 2>&1

  # services: the desktop signs in on its own, the network
  systemctl enable lightdm NetworkManager mylinux-growfs >/dev/null 2>&1
  getent group autologin >/dev/null || groupadd -r autologin; usermod -aG autologin $USER_NAME
  mkdir -p /etc/lightdm/lightdm.conf.d
  printf '[Seat:*]\nautologin-user=$USER_NAME\nautologin-user-timeout=0\nautologin-session=xfce\nuser-session=xfce\n' > /etc/lightdm/lightdm.conf.d/50-mylinux.conf

  # Xfce: the power button (the launcher's Stop) shuts down without asking, nothing locks or blanks the screen
  # (the window is the Mac's to lock)
  d=/home/$USER_NAME/.config/xfce4/xfconf/xfce-perchannel-xml; mkdir -p \$d /home/$USER_NAME/.config/autostart
  cat > \$d/xfce4-power-manager.xml <<'XML'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<channel name=\"xfce4-power-manager\" version=\"1.0\">
  <property name=\"xfce4-power-manager\" type=\"empty\">
    <property name=\"power-button-action\" type=\"uint\" value=\"4\"/>
    <property name=\"logind-handle-power-key\" type=\"bool\" value=\"false\"/>
    <property name=\"dpms-enabled\" type=\"bool\" value=\"false\"/>
    <property name=\"blank-on-ac\" type=\"int\" value=\"0\"/>
    <property name=\"dpms-on-ac-sleep\" type=\"uint\" value=\"0\"/>
    <property name=\"dpms-on-ac-off\" type=\"uint\" value=\"0\"/>
    <property name=\"lock-screen-suspend-hibernate\" type=\"bool\" value=\"false\"/>
    <property name=\"general-notification\" type=\"bool\" value=\"false\"/>
  </property>
</channel>
XML
  cat > \$d/xfce4-screensaver.xml <<'XML'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<channel name=\"xfce4-screensaver\" version=\"1.0\">
  <property name=\"saver\" type=\"empty\"><property name=\"enabled\" type=\"bool\" value=\"false\"/></property>
  <property name=\"lock\" type=\"empty\"><property name=\"enabled\" type=\"bool\" value=\"false\"/></property>
</channel>
XML
  for a in light-locker xfce4-screensaver xscreensaver; do
    [ -e /etc/xdg/autostart/\$a.desktop ] && printf '[Desktop Entry]\nHidden=true\n' > /home/$USER_NAME/.config/autostart/\$a.desktop
  done
  chown -R 1000:1000 /home/$USER_NAME

  rm -f /usr/sbin/policy-rc.d /etc/resolv.conf.build
  rm -rf /var/lib/apt/lists/* /var/log/*.log /var/log/apt/* ; : > /etc/machine-id
  ln -sf ../run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null || true
"

# what the configuration must have left, checked before the disk is closed
for f in etc/sudoers.d/10-mylinux etc/lightdm/lightdm.conf.d/50-mylinux.conf usr/local/bin/mylinux-clipboard usr/local/bin/mylinux-desktop \
         etc/X11/xorg.conf.d/20-mylinux-modesetting.conf usr/bin/startxfce4 usr/sbin/lightdm usr/bin/xclip usr/bin/xrandr usr/bin/stdbuf usr/bin/udevadm; do
  [ -e "$MNT/$f" ] || [ -L "$MNT/$f" ] || die "the image lacks /$f"
done
grep -q '^mac /mnt/mac 9p' "$MNT/etc/fstab" || die "the image's fstab lacks the Mac share"
say "Kernel and initramfs out"
KVER=$(ls "$MNT/lib/modules" | sort -V | tail -1)
[ -s "$MNT/boot/vmlinuz-$KVER" ] && [ -s "$MNT/boot/initrd.img-$KVER" ] || die "no kernel or initramfs for $KVER in the image"
# QEMU starts an uncompressed arm64 Image directly; Debian's vmlinuz is that, gzipped
if gzip -t "$MNT/boot/vmlinuz-$KVER" 2>/dev/null; then gzip -dc "$MNT/boot/vmlinuz-$KVER" > "$OUT/vmlinuz-linux"; else cp "$MNT/boot/vmlinuz-$KVER" "$OUT/vmlinuz-linux"; fi
[ "$(dd if="$OUT/vmlinuz-linux" bs=1 skip=56 count=4 2>/dev/null)" = "ARMd" ] || say "note: the kernel is not a plain arm64 Image ($(file -b "$OUT/vmlinuz-linux" | cut -c1-60))"
cp "$MNT/boot/initrd.img-$KVER" "$OUT/initramfs-linux.img"
REV="$(date -u +%Y.%m.%d)-$KVER"
say "In the image: $(chroot "$MNT" dpkg-query -W -f '${Package}\n' | wc -l) packages, $(du -sh --exclude=proc --exclude=sys --exclude=dev -x "$MNT" 2>/dev/null | cut -f1)"
cleanup; trap - EXIT
mountpoint -q "$MNT" && die "$MNT is still mounted: nothing compressed"
losetup -j "$WORK/rootfs.ext4" | grep -q . && die "rootfs.ext4 is still attached to a loop device: nothing compressed"
e2fsck -fy rootfs.ext4 >/dev/null || true
say "Compressing the root file system"
zstd -q -T0 -${ZSTD_LEVEL:-19} -f rootfs.ext4 -o "$OUT/rootfs.ext4.zst"
(cd "$OUT" && sha256sum vmlinuz-linux initramfs-linux.img rootfs.ext4.zst > SHA256SUMS)
echo "$REV" > "$OUT/KALI-REVISION"
say "Done: $OUT ($REV, $(du -h "$OUT/rootfs.ext4.zst" | cut -f1) compressed)"
