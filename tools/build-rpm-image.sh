#!/bin/bash
# myLinux: builds a GNOME desktop image for Apple silicon (arm64) from a distribution's own packages, for
# Fedora, Rocky Linux and CentOS Stream: dnf installs them into an empty root inside that distribution's official
# container, checked against its signing keys as dnf does. None of them publishes a ready-made virtual machine
# that starts as the launcher's desktops do. Run on the Mac, with Docker (OrbStack's) up:
#   tools/build-rpm-image.sh fedora|rocky|centos [out-dir]
# It leaves, in out-dir (default out/<distro>-build), the files a machine starts from, laid out as Arch's and
# Kali's are (direct kernel boot, a raw ext4 root on /dev/vda):
#   vmlinuz-linux  initramfs-linux.img  rootfs.ext4.zst  SHA256SUMS  <DISTRO>-REVISION
# Inside: GNOME (Wayland), signed in automatically as the distribution's name (password the same, sudo without one),
# its terminal, Files and Firefox, the Mac share at /mnt/mac (~/Mac), and what makes it behave as the launcher's other
# desktops: the clipboard agent (kali/mylinux-clipboard, through Xwayland) and the scale for a Retina display (gnome/).
# The power button is GNOME's own: in a virtual machine it shuts down. SELinux is off (the files carry no labels: dnf
# runs without SELinux here).
set -euo pipefail
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

DISTRO="${1:-}"
case "$DISTRO" in
  fedora) IMAGE=fedora:45; NAME=Fedora ;;
  rocky)  IMAGE=quay.io/rockylinux/rockylinux:10; NAME="Rocky Linux" ;;
  centos) IMAGE=quay.io/centos/centos:stream10; NAME="CentOS Stream" ;;
  *) die "usage: tools/build-rpm-image.sh fedora|rocky|centos [out-dir]" ;;
esac
UPPER=$(echo "$DISTRO" | tr a-z A-Z)

# ---- on the Mac: the distribution's container does the work -------------------------------------------------------------
if [ "${MYLINUX_INSIDE:-0}" != 1 ]; then
  REPO="$(cd "$(dirname "$0")/.." && pwd)"
  OUT="${2:-$REPO/out/$DISTRO-build}"
  command -v docker >/dev/null || die "needs Docker (OrbStack's)"
  mkdir -p "$OUT"
  say "Building $NAME in $IMAGE (arm64)"
  # privileged: dracut and the configuration run in a chroot with /proc, /sys and /dev; the work is on the
  # container's own (case-sensitive) disk, the downloaded packages are kept in a volume between builds
  exec docker run --rm --privileged --platform linux/arm64 --pull=always \
    -e MYLINUX_INSIDE=1 -e ZSTD_LEVEL="${ZSTD_LEVEL:-19}" \
    -v "$REPO:/repo:ro" -v "$OUT:/out" -v "mylinux-rpm-cache-$DISTRO:/var/cache/dnf" \
    "$IMAGE" bash /repo/tools/build-rpm-image.sh "$DISTRO"
fi

# ---- in the container -----------------------------------------------------------------------------------------------------
[ "$(uname -m)" = aarch64 ] || die "needs arm64"
. /etc/os-release
RELEASEVER=${VERSION_ID%%.*}; [ "$DISTRO" = fedora ] || RELEASEVER=$VERSION_ID
USER_NAME=$DISTRO
SIZE_GB=16
R=/work/root
PACKAGES=(
  kernel dracut systemd sudo passwd shadow-utils glibc-langpack-en
  NetworkManager gdm gnome-shell gnome-session-wayland-session gnome-control-center nautilus gnome-text-editor
  firefox xorg-x11-server-Xwayland xclip python3 e2fsprogs
  pipewire-pulseaudio wireplumber dejavu-sans-fonts google-noto-sans-fonts google-noto-color-emoji-fonts dconf ptyxis
  # what GNOME only recommends, and needs here: GDM runs each session's message bus with dbus-daemon (without it the
  # sign-in never starts: "Unable to run session message bus"), pam_systemd (systemd-pam) gives each sign-in its own
  # systemd, on which GNOME runs its session (without it: "org.freedesktop.systemd1 does not exist"), Mesa's drivers draw it, the portal and the keyring
  # serve apps, gvfs gives Files its places
  dbus-daemon systemd-pam mesa-dri-drivers xdg-desktop-portal-gnome gnome-keyring gvfs xdg-user-dirs
  dnf curl less nano git which
)
# the desktop's pictures: Fedora's are GNOME's, Rocky's and CentOS's their own
case "$DISTRO" in
  fedora) PACKAGES+=(gnome-backgrounds) ;;
  *)      PACKAGES+=("$DISTRO-backgrounds") ;;
esac
mkdir -p /work
dnf -y -q install e2fsprogs zstd >/dev/null

say "Installing $NAME $RELEASEVER (GNOME, Firefox) into an empty root"
mkdir -p "$R"
DNF=(dnf -y --installroot="$R" --releasever="$RELEASEVER" --setopt=install_weak_deps=False --setopt=keepcache=True)
# dnf 5 (Fedora) takes the container's own repositories and keys only when told to; dnf 4 (EL 10) does by default
dnf --version 2>/dev/null | grep -q '^dnf5' && DNF+=(--use-host-config)
if [ "$DISTRO" != fedora ]; then
  # xclip is not in EL 10 itself: it comes from EPEL, Fedora's packages for EL, checked against EPEL's key; EPEL's
  # repository is not left in the image
  dnf -y -q install epel-release >/dev/null
fi
for try in 1 2 3; do
  "${DNF[@]}" install "${PACKAGES[@]}" > /work/dnf.log 2>&1 && break
  [ $try = 3 ] && { tail -30 /work/dnf.log >&2; die "installing the packages failed"; }
  say "dnf failed; trying again"; sleep 5
done

if [ "$DISTRO" != fedora ]; then
  # Red Hat's kernel is built without 9p, the Mac share's file system (CONFIG_NET_9P is not set): its modules (9pnet,
  # its virtio transport, and 9p) are built here from that kernel's own source package, against its kernel-devel, into
  # /lib/modules/<version>/extra. The source package is kept in the cache volume between builds.
  KVER=$(ls "$R/lib/modules" | sort -V | tail -1)
  say "Building 9p for $KVER (Red Hat's kernel leaves it out)"
  dnf -y -q install "kernel-devel-$KVER" gcc make elfutils-libelf-devel dnf-plugins-core cpio xz >/dev/null
  mkdir -p /var/cache/dnf/src /work/9p
  SRPM=/var/cache/dnf/src/kernel-${KVER%.*}.src.rpm
  if [ ! -s "$SRPM" ]; then
    (cd /var/cache/dnf/src && dnf -q download --source "kernel-${KVER%.*}" >/dev/null) || die "no source package for kernel $KVER"
  fi
  # ('*/net/9p/*' takes include/net/9p's headers too)
  (cd /work/9p && rpm2cpio "$SRPM" | cpio -idm --quiet 'linux-*.tar.xz' && tar xf linux-*.tar.xz --wildcards '*/fs/9p/*' '*/net/9p/*' '*/include/trace/events/9p.h') \
    || die "unpacking the kernel's source failed"
  SRC=$(ls -d /work/9p/linux-*/ | head -1)
  KB=/usr/src/kernels/$KVER
  make -s -C "$KB" M="$SRC/net/9p" CONFIG_NET_9P=m CONFIG_NET_9P_VIRTIO=m EXTRA_CFLAGS="-I$SRC/include" modules >/work/9p.log 2>&1 \
    || { tail -20 /work/9p.log >&2; die "building 9pnet failed"; }
  make -s -C "$KB" M="$SRC/fs/9p" CONFIG_9P_FS=m KBUILD_EXTRA_SYMBOLS="$SRC/net/9p/Module.symvers" EXTRA_CFLAGS="-I$SRC/include" modules >>/work/9p.log 2>&1 \
    || { tail -20 /work/9p.log >&2; die "building 9p failed"; }
  install -D -m 644 -t "$R/lib/modules/$KVER/extra/9p" "$SRC/net/9p/9pnet.ko" "$SRC/net/9p/9pnet_virtio.ko" "$SRC/fs/9p/9p.ko"
fi

say "Configuring"
for m in proc sys dev dev/pts run tmp; do mkdir -p "$R/$m"; done
mount -t proc proc "$R/proc"; mount --rbind /sys "$R/sys"; mount --rbind /dev "$R/dev"
mount --make-rslave "$R/sys"; mount --make-rslave "$R/dev"
mount -t tmpfs tmpfs "$R/run"; mount -t tmpfs tmpfs "$R/tmp"
cleanup() { set +e; for m in tmp run dev sys proc; do mountpoint -q "$R/$m" && umount -R "$R/$m"; done; }
trap cleanup EXIT
inside() { chroot "$R" /usr/bin/env -i HOME=/root TERM=dumb PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin LANG=C.UTF-8 bash -euo pipefail -c "$1"; }

install -m 755 /repo/kali/mylinux-clipboard "$R/usr/local/bin/mylinux-clipboard"
install -m 644 /repo/kali/60-mylinux-clipboard.rules "$R/etc/udev/rules.d/60-mylinux-clipboard.rules"
install -m 755 /repo/gnome/mylinux-desktop "$R/usr/local/bin/mylinux-desktop"
install -D -m 644 /repo/gnome/mylinux-desktop.desktop "$R/etc/xdg/autostart/mylinux-desktop.desktop"
install -m 755 /repo/gnome/mylinux-scale "$R/usr/local/bin/mylinux-scale"
install -m 644 /repo/gnome/mylinux-scale.service "$R/etc/systemd/system/mylinux-scale.service"
install -D -m 644 /repo/gnome/00-mylinux "$R/etc/dconf/db/local.d/00-mylinux"
inside "
  echo $DISTRO > /etc/hostname
  echo LANG=en_US.UTF-8 > /etc/locale.conf
  ln -sf ../usr/share/zoneinfo/UTC /etc/localtime
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config 2>/dev/null || true

  # the account: the distribution's name, the same password (uid 1000, as the Mac share's files are mapped), sudo
  # without asking
  id $USER_NAME >/dev/null 2>&1 || useradd -m -u 1000 -G wheel,audio,video,input $USER_NAME
  echo '$USER_NAME:$USER_NAME' | chpasswd; passwd -l root >/dev/null
  echo '$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-mylinux; chmod 440 /etc/sudoers.d/10-mylinux

  # boot: a raw ext4 on /dev/vda, grown to the machine's disk size at each start; the Mac share
  echo '/dev/vda / ext4 rw,relatime 0 1' > /etc/fstab
  echo 'mac /mnt/mac 9p trans=virtio,version=9p2000.L,msize=524288,access=client,nofail,x-systemd.automount,x-systemd.device-timeout=5 0 0' >> /etc/fstab
  mkdir -p /mnt/mac; ln -sfn /mnt/mac /home/$USER_NAME/Mac
  printf '[Unit]\nDescription=myLinux: the root file system takes the whole disk\nAfter=systemd-remount-fs.service\n\n[Service]\nType=oneshot\nExecStart=/usr/sbin/resize2fs /dev/vda\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/mylinux-growfs.service
  KVER=\$(ls /lib/modules | sort -V | tail -1)
  depmod -a \$KVER
  dracut -q -f --no-hostonly --kver \$KVER --add-drivers 'virtio_blk virtio_pci virtio_net virtio_gpu virtio_console virtio_input 9p 9pnet_virtio' /boot/initramfs-linux.img \$KVER

  # services: the desktop signs in on its own, the network, the power button
  systemctl enable gdm NetworkManager mylinux-growfs mylinux-scale >/dev/null 2>&1
  systemctl set-default graphical.target >/dev/null 2>&1
  printf '[daemon]\nAutomaticLoginEnable=True\nAutomaticLogin=$USER_NAME\n' > /etc/gdm/custom.conf
  # GNOME's settings for every account (gnome/00-mylinux: nothing locks or blanks, no first-run tour)
  mkdir -p /etc/dconf/profile; printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user; dconf update
  mkdir -p /home/$USER_NAME/.config; : > /home/$USER_NAME/.config/gnome-initial-setup-done
  chown -R 1000:1000 /home/$USER_NAME

  rm -rf /var/cache/dnf/* /var/log/*.log; : > /etc/machine-id
"
[ "$DISTRO" = fedora ] || rm -f "$R"/etc/yum.repos.d/epel*.repo

# what the configuration must have left, checked before the disk is made
for f in etc/sudoers.d/10-mylinux etc/gdm/custom.conf usr/local/bin/mylinux-clipboard usr/local/bin/mylinux-desktop usr/local/bin/mylinux-scale \
         etc/dconf/db/local usr/bin/gnome-shell usr/sbin/gdm usr/bin/xclip usr/bin/firefox usr/bin/dbus-daemon usr/lib64/security/pam_systemd.so usr/bin/dnf boot/initramfs-linux.img; do
  [ -e "$R/$f" ] || [ -L "$R/$f" ] || die "the image lacks /$f"
done
grep -q '^mac /mnt/mac 9p' "$R/etc/fstab" || die "the image's fstab lacks the Mac share"
[ -n "$(ls "$R"/lib/modules/*/extra/9p/9p.ko "$R"/lib/modules/*/kernel/fs/9p/9p.ko* 2>/dev/null)" ] || die "the image has no 9p for the Mac share"

say "Kernel and initramfs out"
KVER=$(ls "$R/lib/modules" | sort -V | tail -1)
K="$R/lib/modules/$KVER/vmlinuz"; [ -s "$K" ] || K="$R/boot/vmlinuz-$KVER"
[ -s "$K" ] || die "no kernel for $KVER in the image"
# QEMU starts an arm64 Image directly, and unpacks an EFI zboot kernel only when gzip packed it; these come as zboot
# with zstd: the Image is taken out of it here (the header gives the payload's offset, size and compression)
if [ "$(dd if="$K" bs=1 skip=4 count=4 2>/dev/null)" = zimg ]; then
  off=$(od -An -tu4 -j8 -N4 "$K" | tr -d ' '); size=$(od -An -tu4 -j12 -N4 "$K" | tr -d ' ')
  comp=$(dd if="$K" bs=1 skip=24 count=8 2>/dev/null | tr -d '\0')
  case "$comp" in zstd) unpack="zstd -dc" ;; gzip) unpack="gzip -dc" ;; *) die "the kernel is packed with $comp" ;; esac
  tail -c +$((off + 1)) "$K" | head -c "$size" | $unpack > /out/vmlinuz-linux
else
  cp "$K" /out/vmlinuz-linux
fi
[ "$(dd if=/out/vmlinuz-linux bs=1 skip=56 count=4 2>/dev/null)" = ARMd ] || die "the kernel is not an arm64 Image"
cp "$R/boot/initramfs-linux.img" /out/initramfs-linux.img
REV="$(date -u +%Y.%m.%d)-$VERSION_ID-$KVER"
say "In the image: $(chroot "$R" rpm -qa | wc -l) packages, $(du -sh -x "$R" 2>/dev/null | cut -f1)"
cleanup; trap - EXIT

say "Making the root file system"
rm -f /work/rootfs.ext4; truncate -s ${SIZE_GB}G /work/rootfs.ext4
mkfs.ext4 -q -L $DISTRO-root -O ^orphan_file -d "$R" /work/rootfs.ext4
e2fsck -fy /work/rootfs.ext4 >/dev/null || true
say "Compressing it"
zstd -q -T0 -"${ZSTD_LEVEL:-19}" -f /work/rootfs.ext4 -o /out/rootfs.ext4.zst
(cd /out && sha256sum vmlinuz-linux initramfs-linux.img rootfs.ext4.zst > SHA256SUMS)
echo "$REV" > "/out/$UPPER-REVISION"
say "Done: $REV, $(du -h /out/rootfs.ext4.zst | cut -f1) compressed"
