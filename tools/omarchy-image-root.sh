#!/bin/bash
# myLinux: the root half of tools/build-omarchy-image.sh, run as root in an arm64 Linux (the OrbStack "debian" machine:
# it has mkfs.vfat, mtools, btrfs and loop devices; apt-get install dosfstools mtools btrfs-progs zstd curl).
#   omarchy-image-root.sh cidata <dir> <disk GB>
#       <dir>/cidata.img: the drive labeled CIDATA that has Omarchy's ISO install itself with nobody at the keyboard
#       (its "unattended installs": the configurator's own answer files), onto /dev/vda, unencrypted, with deferred
#       provisioning: no user; the first start of each machine makes one (Omarchy's omarchy-provision-owner).
#       The answers are those Omarchy's own aarch64 install test gives (omarchy-iso test/arm64-install and
#       test/integration.d/base-test.sh), with the stable channel's mirror of Arch Linux ARM.
set -euo pipefail
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ "$(uname -m)" = aarch64 ] || die "needs an arm64 Linux"

cidata() {
  local dir=$1 gb=$2 c=$1/cidata
  local mib=1048576 gib=1073741824
  local boot_start=$mib boot_size=$((2 * gib)) main_start=$((2 * gib + mib))
  local main_size=$((gb * gib - main_start - mib))
  (( main_size > 6 * gib )) || die "a disk of $gb GB leaves too little for the root"
  rm -rf "$c"; mkdir -p "$c"
  cat > "$c/user_configuration.json" <<EOF
{
    "app_config": null,
    "archinstall-language": "English",
    "auth_config": {},
    "audio_config": { "audio": "pipewire" },
    "bootloader_config": { "bootloader": "Limine", "uki": false, "removable": false },
    "custom_commands": [],
    "omarchy_install": {
        "mode": "full_disk",
        "defer_provisioning": true,
        "target_mount": "/mnt",
        "boot": { "esp_mount": "/boot", "esp_path": "/EFI/limine", "efi_binary": "limine_aa64.efi", "enable_fallback": true },
        "storage": { "kernel": "linux-omarchy" }
    },
    "disk_config": {
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "/dev/vda",
                "partitions": [
                    {
                        "btrfs": [], "dev_path": null, "flags": [ "boot", "esp" ], "fs_type": "fat32",
                        "mount_options": [], "mountpoint": "/boot", "obj_id": "ea21d3f2-82bb-49cc-ab5d-6f81ae94e18d",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $boot_start },
                        "status": "create", "type": "primary"
                    },
                    {
                        "btrfs": [
                            { "mountpoint": "/", "name": "@" },
                            { "mountpoint": "/home", "name": "@home" },
                            { "mountpoint": "/var/log", "name": "@log" },
                            { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
                        ],
                        "dev_path": null, "flags": [], "fs_type": "btrfs", "mount_options": [ "compress=zstd" ],
                        "mountpoint": null, "obj_id": "8c2c2b92-1070-455d-b76a-56263bab24aa",
                        "size": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_size },
                        "start": { "sector_size": { "unit": "B", "value": 512 }, "unit": "B", "value": $main_start },
                        "status": "create", "type": "primary"
                    }
                ],
                "wipe": true
            }
        ]
    },
    "hostname": "omarchy",
    "kernels": [ "linux-omarchy" ],
    "network_config": { "type": "iso" },
    "ntp": true,
    "parallel_downloads": 8,
    "script": null,
    "services": [],
    "swap": true,
    "timezone": "UTC",
    "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
    "mirror_config": {
        "custom_repositories": [],
        "custom_servers": [ { "url": "https://arm-stable-mirror.omarchy.org/\$arch/\$repo" } ],
        "mirror_regions": {},
        "optional_repositories": []
    },
    "packages": [ "base-devel", "git", "omarchy-keyring", "omarchy-settings", "omarchy" ],
    "profile_config": { "gfx_driver": null, "greeter": null, "profile": {} },
    "version": "3.0.9"
}
EOF
  : > "$c/defer-provisioning"
  echo false > "$c/user_encrypt_installation.txt"
  rm -f "$dir/cidata.img"; truncate -s 4M "$dir/cidata.img"
  mkfs.vfat -n CIDATA "$dir/cidata.img" >/dev/null
  mcopy -i "$dir/cidata.img" "$c"/* ::/
  say "cidata: $dir/cidata.img (deferred provisioning, a $gb GB disk)"
}

# finish <disk.raw> <try-omarchy source .tar.gz> <repo>: the installed disk, never started, made into the image, offline
# (nothing of it runs here but pacman, makepkg and their hooks, in a chroot):
#   - Try Omarchy's guest package, built from its source as nobody, with what it depends on from Omarchy's mirrors
#   - myLinux's pieces: omarchy/native (the credentials of each start, the keyring), omarchy/answers (the first-start
#     answers) and omarchy/session (the session tool, enabled for every graphical session)
#   - sealed as Omarchy's own VM images are (omarchy-iso test/vm-image/vm-seal): no machine ID (each machine makes its
#     own, and Limine's entry names none, so a kernel update replaces it in place), no keyring, no host keys, no
#     seeds or leases; the factory snapshot taken again, so Omarchy's factory reset keeps the Mac integration
finish() {
  local raw=$1 src=$2 repo=$3 i
  B=/root/omarchy-build R=/root/omarchy-build/root L=""            # (globals: the EXIT trap uses them)
  [ -f "$raw" ] && [ -f "$src" ] && [ -d "$repo/omarchy/native" ] || die "usage: $0 finish <disk.raw> <src.tar.gz> <repo>"
  mkdir -p "$B" "$R"
  cleanup() { set +e; umount -R "$R" 2>/dev/null; umount "$B/top" 2>/dev/null; [ -z "$L" ] || losetup -d "$L"; }
  trap cleanup EXIT
  L=$(losetup -fP --show "$raw")
  for i in $(seq 1 50); do [ -b "${L}p2" ] && break; sleep 0.1; done
  mount -o subvol=@,compress=zstd "${L}p2" "$R"
  mount -o subvol=@home,compress=zstd "${L}p2" "$R/home"
  mount -o subvol=@log,compress=zstd "${L}p2" "$R/var/log"
  mount -o subvol=@pkg,compress=zstd "${L}p2" "$R/var/cache/pacman/pkg"
  mount "${L}p1" "$R/boot"
  [ -f "$R/var/lib/omarchy/provisioning/pending" ] || die "the disk has no deferred first-start setup: not a fresh deferred install"
  mount -t proc proc "$R/proc"; mount --rbind /sys "$R/sys"; mount --rbind /dev "$R/dev"
  mount -t tmpfs tmpfs "$R/run"; mount -t tmpfs tmpfs "$R/tmp"
  mkdir -p "$R/run/systemd/resolve"; cp -L /etc/resolv.conf "$R/run/systemd/resolve/stub-resolv.conf"
  cp -L /etc/resolv.conf "$R/run/systemd/resolve/resolv.conf"
  chr() { chroot "$R" /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/bin LANG=C.UTF-8 TERM=dumb "$@"; }

  say "Try Omarchy's guest package, from $(basename "$src")"
  mkdir -p "$R/tmp/build"; tar -xzf "$src" -C "$R/tmp/build" --strip-components=1
  local P=/tmp/build/guest/package/try-omarchy
  cp "$R/tmp/build/LICENSE" "$R$P/"
  local deps
  deps=$(sed -n '/^depends=(/,/^)/p; /^optdepends=(/,/^)/p' "$R$P/PKGBUILD" | grep -o "'[^':]*" | tr -d "'" | tr '\n' ' ')
  chr pacman -Sy --needed --noconfirm $deps
  chown -R 65534:65534 "$R/tmp/build"
  chr runuser -u nobody -- env HOME=/tmp/build bash -c "cd $P && makepkg -f --nodeps" > "$B/makepkg.log" 2>&1 || { tail -20 "$B/makepkg.log"; die "makepkg failed"; }
  chr sh -c "pacman -U --noconfirm $P/try-omarchy-*.pkg.tar.*"
  chr pacman -Q try-omarchy

  say "myLinux's pieces"
  install -D -m 0755 "$repo/omarchy/native/mylinux-credentials" "$R/usr/lib/mylinux/credentials"
  install -m 0644 "$repo/omarchy/native/mylinux-credentials.service" "$repo/omarchy/native/mylinux-pacman-keyring.service" "$R/etc/systemd/system/"
  chr systemctl enable mylinux-credentials.service mylinux-pacman-keyring.service
  install -d -m 0700 "$R/var/lib/mylinux" "$R/var/lib/mylinux/bin"
  install -m 0755 "$repo/omarchy/answers/provision" "$R/var/lib/mylinux/provision"
  install -m 0755 "$repo/omarchy/answers/gum" "$R/var/lib/mylinux/bin/gum"
  install -D -m 0644 "$repo/omarchy/answers/20-mylinux-answers.conf" "$R/etc/systemd/system/omarchy-provision-owner.service.d/20-mylinux-answers.conf"
  install -m 0755 "$repo/omarchy/session/omarchy-session" "$R/usr/local/bin/omarchy-session"
  local u
  for u in omarchy-session-save.service omarchy-session-save.timer omarchy-session-restore.service omarchy-session-agent.service; do
    sed 's|%h/.local/bin/omarchy-session|/usr/local/bin/omarchy-session|g' "$repo/omarchy/session/$u" > "$R/etc/systemd/user/$u"
  done
  chr systemctl --global enable omarchy-session-save.timer omarchy-session-restore.service omarchy-session-agent.service

  say "Sealing"
  local mid; mid=$(cat "$R/etc/machine-id")
  [[ $mid =~ ^[0-9a-f]{32}$ ]] || die "no machine ID to take out ($mid)"
  sed -i "s/machine-id=$mid *//" "$R/boot/limine.conf"
  ! grep -q "machine-id=$mid" "$R/boot/limine.conf" || die "Limine's entry still names the build's machine"
  : > "$R/etc/machine-id"; rm -f "$R/var/lib/dbus/machine-id"
  rm -rf "$R/etc/pacman.d/gnupg" "$R/tmp/build"
  rm -f "$R"/etc/ssh/ssh_host_* "$R/var/lib/systemd/random-seed" "$R/var/lib/systemd/credential.secret"
  rm -f "$R"/var/lib/NetworkManager/*.lease "$R/var/lib/NetworkManager/secret_key" "$R/var/lib/NetworkManager/seen-bssids" \
    "$R/var/lib/NetworkManager/timestamps" "$R/var/lib/NetworkManager/NetworkManager.state"
  rm -rf "$R"/var/log/journal/* "$R"/var/cache/pacman/pkg/*
  umount -R "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp" 2>/dev/null || umount -l "$R/sys" "$R/dev" 2>/dev/null || true
  # the factory snapshot Omarchy's factory reset goes back to: this system, as sealed
  mkdir -p "$B/top"; mount -o subvolid=5 "${L}p2" "$B/top"
  if [ -d "$B/top/@factory" ]; then
    btrfs property set -ts "$B/top/@factory" ro false; btrfs subvolume delete "$B/top/@factory" >/dev/null
    btrfs subvolume snapshot -r "$B/top/@" "$B/top/@factory" >/dev/null
  fi
  sync; umount "$B/top"; umount -R "$R"; losetup -d "$L"; L=""
  say "finished: $raw"
}

case "${1:-}" in
  cidata) [ $# = 3 ] || die "usage: $0 cidata <dir> <disk GB>"; cidata "$2" "$3" ;;
  finish) [ $# = 4 ] || die "usage: $0 finish <disk.raw> <src.tar.gz> <repo>"; finish "$2" "$3" "$4" ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
