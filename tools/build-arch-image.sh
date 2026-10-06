#!/bin/bash
# myLinux: builds the Arch Linux (KDE Plasma) desktop image, for Apple silicon (aarch64), from Arch Linux ARM's
# generic root filesystem. Run as root on an arm64 Linux (the OrbStack "debian" machine):
#   orb -m debian sudo bash tools/build-arch-image.sh [out-dir]
# It leaves, in out-dir (default out/arch-build, beside this repo), the files a machine starts from, laid out as
# Omarchy's are (direct kernel boot, a raw ext4 root on /dev/vda):
#   vmlinuz-linux  initramfs-linux.img  rootfs.ext4.zst  SHA256SUMS  ARCH-REVISION
# Inside: Plasma (Wayland) signed in automatically as "arch" (sudo without a password), Konsole, Dolphin, Firefox,
# PipeWire sound, the Mac share at /mnt/mac (~/Mac), and the clipboard agent (arch/mylinux-clipboard) that speaks
# Try Omarchy's clipboard protocol, so the launcher's bridge serves both.
set -euo pipefail
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(uname -m)" = aarch64 ] || die "needs an arm64 Linux (the OrbStack debian machine)"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/out/arch-build}"
WORK=/root/arch-build                          # on Linux's own disk: the Mac's folders are case-insensitive
SIZE_GB=16
TARBALL_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
# Arch Linux ARM Build System <builder@archlinuxarm.org>
ALARM_KEY=68B3537F39A313B3E574D06777193F152BDBE6A6
PACKAGES=(
  linux-aarch64 mkinitcpio sudo
  plasma-desktop sddm sddm-kcm kscreen plasma-pa plasma-nm breeze-gtk kde-gtk-config xdg-desktop-portal-kde
  konsole dolphin kio-extras smbclient kate ark spectacle gwenview firefox
  pipewire pipewire-pulse wireplumber pipewire-jack qt6-multimedia-ffmpeg tesseract-data-eng
  noto-fonts noto-fonts-emoji ttf-dejavu
  networkmanager openssh wl-clipboard python git nano less which man-db
)
USER_NAME=arch

for t in bsdtar mkfs.ext4 losetup zstd curl gpg; do command -v $t >/dev/null || die "missing $t (apt-get install libarchive-tools e2fsprogs zstd curl gpg)"; done
mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ---- Arch Linux ARM's root filesystem, signature checked -----------------------------------------------------------
if [ ! -f alarm.tar.gz ] || [ "${FRESH:-0}" = 1 ]; then
  say "Downloading Arch Linux ARM (aarch64)"
  curl -fL --retry 3 -o alarm.tar.gz.part "$TARBALL_URL"
  curl -fL --retry 3 -o alarm.tar.gz.sig "$TARBALL_URL.sig"
  mv alarm.tar.gz.part alarm.tar.gz
fi
export GNUPGHOME="$WORK/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
# the key once (kept in $WORK/gnupg): keyservers answer "No data" now and then
gpg -q --batch --list-keys "$ALARM_KEY" >/dev/null 2>&1 \
  || gpg -q --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$ALARM_KEY" 2>/dev/null \
  || gpg -q --batch --keyserver hkps://keys.openpgp.org --recv-keys "$ALARM_KEY"
gpg --batch --status-fd 1 --verify alarm.tar.gz.sig alarm.tar.gz 2>/dev/null | grep -q "VALIDSIG $ALARM_KEY" \
  || die "alarm.tar.gz is not signed by Arch Linux ARM's build key"
say "Signature good (Arch Linux ARM Build System)"

# ---- the disk: one ext4 file system, no partitions (root=/dev/vda) ----------------------------------------------------
MNT="$WORK/mnt"
# Anything still running inside (pacman-key's gpg-agent) keeps the file system busy: a lazy unmount then left it
# attached with its last writes unflushed, and the compressed image lacked the whole configuration
kill_inside() {
  for p in /proc/[0-9]*; do
    [ "$(readlink "$p/root" 2>/dev/null)" = "$MNT" ] && kill "${p#/proc/}" 2>/dev/null
  done
  sleep 1
}
cleanup() {
  set +e
  kill_inside
  for m in var/cache/pacman/pkg dev/pts dev proc sys run tmp; do mountpoint -q "$MNT/$m" && umount -R "$MNT/$m"; done
  mountpoint -q "$MNT" && umount "$MNT"
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT
rm -f rootfs.ext4; truncate -s ${SIZE_GB}G rootfs.ext4
mkfs.ext4 -q -L arch-root -O ^orphan_file rootfs.ext4
mkdir -p "$MNT"; LOOP=$(losetup --find --show rootfs.ext4); mount "$LOOP" "$MNT"
say "Unpacking"
bsdtar -xpf alarm.tar.gz -C "$MNT"

for m in proc sys dev dev/pts run tmp var/cache/pacman/pkg; do mkdir -p "$MNT/$m"; done
mount -t proc proc "$MNT/proc"; mount --rbind /sys "$MNT/sys"; mount --rbind /dev "$MNT/dev"
mount -t tmpfs tmpfs "$MNT/run"; mount -t tmpfs tmpfs "$MNT/tmp"
# the packages are kept here between builds: a failed or repeated build does not fetch them again
mkdir -p "$WORK/pkgcache"; mount --bind "$WORK/pkgcache" "$MNT/var/cache/pacman/pkg"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf.build"
inside() { chroot "$MNT" /usr/bin/env -i HOME=/root TERM=dumb PATH=/usr/local/sbin:/usr/local/bin:/usr/bin LANG=C.UTF-8 bash -euo pipefail -c "$1"; }

say "Packages (Plasma, Konsole, Dolphin, Firefox, PipeWire)"
inside "
  rm -f /etc/resolv.conf; cp /etc/resolv.conf.build /etc/resolv.conf
  sed -i 's/^CheckSpace/#CheckSpace/; s/^#ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
  pacman-key --init >/dev/null; pacman-key --populate archlinuxarm >/dev/null
  # Arch Linux ARM's mirrors stall now and then: again, with what came down kept
  for try in 1 2 3 4 5; do
    pacman -Syu --noconfirm --needed ${PACKAGES[*]} && break
    [ \$try = 5 ] && exit 1; echo 'pacman failed; trying again'; sleep 5
  done
  gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true
  # no hardware in a virtual machine needs firmware: about 600 MB less
  pacman -Rdd --noconfirm \$(pacman -Qq | grep '^linux-firmware') 2>/dev/null || true
"

say "Configuring"
install -m 755 "$REPO/arch/mylinux-clipboard" "$MNT/usr/local/bin/mylinux-clipboard"
install -m 644 "$REPO/arch/mylinux-clipboard.service" "$MNT/etc/systemd/user/mylinux-clipboard.service"
install -m 755 "$REPO/arch/mylinux-scale" "$MNT/usr/local/bin/mylinux-scale"
install -D -m 644 "$REPO/arch/mylinux-scale.desktop" "$MNT/etc/xdg/autostart/mylinux-scale.desktop"
install -m 644 "$REPO/arch/60-mylinux-clipboard.rules" "$MNT/etc/udev/rules.d/60-mylinux-clipboard.rules"
inside "
  echo arch > /etc/hostname
  sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; locale-gen >/dev/null; echo LANG=en_US.UTF-8 > /etc/locale.conf
  ln -sf /usr/share/zoneinfo/UTC /etc/localtime

  # the account: alarm's sample user out, ours in (uid 1000, as the Mac share's files are mapped)
  userdel -r alarm 2>/dev/null || true
  id $USER_NAME >/dev/null 2>&1 || useradd -m -u 1000 -G wheel,audio,video,input -s /bin/bash $USER_NAME
  passwd -d $USER_NAME >/dev/null; passwd -l root >/dev/null
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-wheel; chmod 440 /etc/sudoers.d/10-wheel

  # boot: a raw ext4 on /dev/vda, an initramfs with the virtio drivers (not one fitted to the build machine)
  echo '/dev/vda / ext4 rw,relatime 0 1' > /etc/fstab
  echo 'mac /mnt/mac 9p trans=virtio,version=9p2000.L,msize=524288,access=client,nofail,x-systemd.automount,x-systemd.device-timeout=5 0 0' >> /etc/fstab
  mkdir -p /mnt/mac; ln -sfn /mnt/mac /home/$USER_NAME/Mac
  sed -i 's/^MODULES=.*/MODULES=(virtio_pci virtio_blk virtio_gpu virtio_net virtio_console virtio_input virtio_balloon virtio_rng 9p 9pnet_virtio)/; s/^HOOKS=.*/HOOKS=(base udev modconf keyboard block filesystems fsck)/' /etc/mkinitcpio.conf
  sed -i \"s/^PRESETS=.*/PRESETS=('default')/\" /etc/mkinitcpio.d/linux-aarch64.preset
  rm -f /boot/initramfs-linux-fallback.img
  mkinitcpio -p linux-aarch64 >/dev/null

  # services: the desktop signs in on its own, the network, ssh (the launcher forwards a port to it)
  systemctl enable sddm NetworkManager sshd >/dev/null 2>&1
  systemctl disable systemd-networkd 2>/dev/null || true
  mkdir -p /etc/sddm.conf.d
  printf '[Autologin]\nUser=$USER_NAME\nSession=plasma\nRelogin=true\n\n[General]\nDisplayServer=wayland\n' > /etc/sddm.conf.d/mylinux.conf
  systemctl --global enable mylinux-clipboard.service >/dev/null 2>&1

  # KWin on QEMU's virgl (drawn by ANGLE on the Mac): desktop OpenGL hung its first frame for good, the main thread
  # in virtio_gpu_wait_ioctl on a fence the host never signalled (the timer queries KWin times its frames with);
  # OpenGL ES without timer queries draws
  printf 'KWIN_COMPOSE=O2ES\nMESA_EXTENSION_OVERRIDE=-GL_ARB_timer_query -GL_EXT_timer_query -GL_EXT_disjoint_timer_query\n' >> /etc/environment

  # Plasma: no screen lock (no password to unlock with), no first-run welcome
  install -d -o 1000 -g 1000 /home/$USER_NAME/.config
  printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > /home/$USER_NAME/.config/kscreenlockerrc
  printf '[General]\nShouldShow=false\n' > /home/$USER_NAME/.config/plasma-welcomerc
  # no KDE wallet: with no password to open it, it asks to be set up when an app first wants it, and apps (the
  # ChatGPT app) wait on that; Chromium-based apps keep their logins themselves without it
  printf '[Wallet]\nEnabled=false\nFirst Use=false\n' > /home/$USER_NAME/.config/kwalletrc
  # the power button (QMP system_powerdown: the launcher's Stop) shuts down; Plasma's own default asks first, and
  # nobody answers that inside a machine being stopped
  printf '[AC][SuspendAndShutdown]\nAutoSuspendAction=0\nPowerButtonAction=8\n[AC][Display]\nTurnOffDisplayWhenIdle=false\nDimDisplayWhenIdle=false\n' > /home/$USER_NAME/.config/powerdevilrc
  chown -R 1000:1000 /home/$USER_NAME
  rm -f /etc/resolv.conf.build; ln -sf ../run/NetworkManager/resolv.conf /etc/resolv.conf 2>/dev/null || true
"

# what the configuration must have left, checked before the disk is closed
for f in etc/sudoers.d/10-wheel etc/sddm.conf.d/mylinux.conf etc/systemd/system/display-manager.service usr/local/bin/mylinux-clipboard; do
  [ -e "$MNT/$f" ] || [ -L "$MNT/$f" ] || die "the image lacks /$f"
done
grep -q '^mac /mnt/mac 9p' "$MNT/etc/fstab" || die "the image's fstab lacks the Mac share"
grep -q '^KWIN_COMPOSE=O2ES' "$MNT/etc/environment" || die "the image's /etc/environment lacks KWin's settings"
grep -q '^Enabled=false' "$MNT/home/$USER_NAME/.config/kwalletrc" || die "the image's KDE wallet is not switched off"
say "Kernel and initramfs out"
cp "$MNT/boot/Image" "$OUT/vmlinuz-linux"
cp "$MNT/boot/initramfs-linux.img" "$OUT/initramfs-linux.img"
REV="$(date -u +%Y.%m.%d)-$(chroot "$MNT" pacman -Q linux-aarch64 | awk '{print $2}')"
cleanup; trap - EXIT
mountpoint -q "$MNT" && die "$MNT is still mounted: nothing compressed"
losetup -j "$WORK/rootfs.ext4" | grep -q . && die "rootfs.ext4 is still attached to a loop device: nothing compressed"
gpgconf --kill all 2>/dev/null || true
e2fsck -fy rootfs.ext4 >/dev/null || true
say "Compressing the root file system"
zstd -q -T0 -10 -f rootfs.ext4 -o "$OUT/rootfs.ext4.zst"
(cd "$OUT" && sha256sum vmlinuz-linux initramfs-linux.img rootfs.ext4.zst > SHA256SUMS)
echo "$REV" > "$OUT/ARCH-REVISION"
say "Done: $OUT ($REV, $(du -h "$OUT/rootfs.ext4.zst" | cut -f1) compressed)"
